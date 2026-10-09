import Foundation
import OSLog

/// Everything needed to play one MKV through AVPlayer: the probe, the segment muxer and the loopback server that
/// hands HLS to AVPlayer. Create it with `start`; call `stop` when playback ends.
final class RemuxSession: @unchecked Sendable {
    struct Failure: Error, Equatable, LocalizedError {
        var message: String
        /// Whether the compatibility engine might play what this one can't (a codec it has no way to copy or convert).
        var retryWithCompatibilityEngine = false
        var errorDescription: String? { message }
    }

    let probe: MKVProbeResult
    let video: ProbedStream
    /// Nil for a file without audio.
    let audio: ProbedStream?
    let segments: [SegmentSpec]
    /// What AVPlayer loads.
    let playbackURL: URL

    private let muxer: SegmentMuxer
    private let server: LoopbackServer
    private let fileBytes: Int64
    private static let log = Logger(subsystem: "com.joaocadide.nitpicker", category: "remux")

    private init(probe: MKVProbeResult, video: ProbedStream, audio: ProbedStream?, segments: [SegmentSpec], muxer: SegmentMuxer, server: LoopbackServer, url: URL, fileBytes: Int64) {
        self.fileBytes = fileBytes
        self.probe = probe
        self.video = video
        self.audio = audio
        self.segments = segments
        self.muxer = muxer
        self.server = server
        playbackURL = url
    }

    /// Pass the `probe` of an earlier session on the same file to skip probing it again (switching audio tracks), and
    /// `audioStreamID` to play that track instead of choosing one.
    static func start(url: URL, probe knownProbe: MKVProbeResult? = nil, audioStreamID: Int? = nil, preferredAudioLanguage: String?) async throws -> RemuxSession {
        var probe = if let knownProbe { knownProbe } else { try await MKVProbe.probe(url: url) }
        if probe.keyframes.isEmpty, let video = probe.video.first, RemuxSupport.canCopyVideo(codec: video.codec) {
            // No Cues: the keyframes have to be found by reading the file.
            probe.keyframes = try await MKVProbe.scanKeyframes(url: url, videoIndex: video.id)
        }
        let plan = try plan(for: probe, preferredAudioLanguage: preferredAudioLanguage, audioStreamID: audioStreamID)
        try Task.checkCancellation()

        let converted = plan.audio.map { !RemuxSupport.canCopyAudio(codec: $0.codec) } ?? false
        let muxer = try await SegmentMuxer.open(path: url.path, video: plan.video, audio: plan.audio, segments: plan.segments, transcodeAudio: converted)
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard let variant = HLSPlaylists.variant(
            video: plan.video, audio: plan.audio, audioConverted: converted, initSegment: muxer.initSegment, fileBytes: fileBytes, duration: probe.duration
        ) else {
            muxer.close()
            throw Failure(message: "This file's codecs can't be described to the player.")
        }
        let master = Data(HLSPlaylists.master(variant).utf8)
        let media = Data(HLSPlaylists.media(segments: plan.segments).utf8)
        let initData = Data(muxer.initSegment)
        let count = plan.segments.count

        let server: LoopbackServer
        let base: URL
        do {
            server = try LoopbackServer { path in
                switch path {
                case "master.m3u8": return HTTPResource(body: master, contentType: "application/vnd.apple.mpegurl")
                case "video.m3u8": return HTTPResource(body: media, contentType: "application/vnd.apple.mpegurl")
                case "init.mp4": return HTTPResource(body: initData, contentType: "video/mp4")
                default:
                    guard path.hasPrefix("seg_"), path.hasSuffix(".m4s"), let index = Int(path.dropFirst(4).dropLast(4)), (0..<count).contains(index) else { return nil }
                    do {
                        return HTTPResource(body: try await muxer.segment(index), contentType: "video/iso.segment")
                    } catch {
                        log.error("segment \(index) failed: \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
            }
            base = try await server.start()
        } catch {
            muxer.close()
            throw Failure(message: "Couldn't start the local player service: \(error)")
        }
        log.info("remux session: \(plan.segments.count) segments, video \(plan.video.codec, privacy: .public), audio \(plan.audio?.codec ?? "none", privacy: .public)")
        return RemuxSession(
            probe: probe, video: plan.video, audio: plan.audio, segments: plan.segments, muxer: muxer, server: server,
            url: base.appendingPathComponent("master.m3u8"), fileBytes: fileBytes
        )
    }

    struct Plan: Equatable {
        var video: ProbedStream
        var audio: ProbedStream?
        var segments: [SegmentSpec]
    }

    /// Decides what to copy, or says why the file can't be played yet. Pure, so each refusal is tested.
    static func plan(for probe: MKVProbeResult, preferredAudioLanguage: String?, audioStreamID: Int? = nil) throws -> Plan {
        guard let video = probe.video.first else { throw Failure(message: "This file has no video.", retryWithCompatibilityEngine: true) }
        guard RemuxSupport.canCopyVideo(codec: video.codec) else {
            throw Failure(message: "This file's video (\(video.codec.uppercased())) isn't supported yet.", retryWithCompatibilityEngine: true)
        }
        var audio: ProbedStream?
        if !probe.audio.isEmpty {
            audio = probe.audio.first { $0.id == audioStreamID && RemuxSupport.canPlayAudio(codec: $0.codec) }
                ?? RemuxSupport.chooseAudio(from: probe.streams, preferredLanguage: preferredAudioLanguage)
            guard audio != nil else {
                let names = Set(probe.audio.map { $0.codec.uppercased() }).sorted().joined(separator: ", ")
                throw Failure(message: "This file's audio (\(names)) isn't supported yet.", retryWithCompatibilityEngine: true)
            }
        }
        let segments = SegmentPlanner.plan(keyframes: probe.keyframes, duration: probe.duration)
        guard !segments.isEmpty else {
            throw Failure(message: "This file has no seek index, which isn't supported yet.", retryWithCompatibilityEngine: true)
        }
        return Plan(video: video, audio: audio, segments: segments)
    }

    /// What the file is, in the app's own terms. AVFoundation can't describe an HLS stream's tracks the way it
    /// describes a file's, so the probe and the init segment are the source.
    var mediaInfo: MediaInfo {
        Self.mediaInfo(probe: probe, video: video, audio: audio, fileBytes: fileBytes)
    }

    /// The one audio track being played, with codec details and whether it carries Spatial Audio objects (the muxer reads
    /// that from the E-AC-3 bitstream and writes it into the `dec3` record).
    var audioTrack: MediaTrack? {
        guard let audio else { return nil }
        return Self.mediaTrack(for: audio, isSpatial: Self.isSpatial(audio, initSegment: muxer.initSegment))
    }

    private static func isSpatial(_ audio: ProbedStream, initSegment: [UInt8]) -> Bool {
        audio.codec == "eac3" && (MP4Boxes.payload(of: "dec3", in: initSegment).map { AudioFormatDetection.isJOC(dec3: Data($0)) } ?? false)
    }

    /// Whether an audio track that isn't playing carries Spatial Audio objects. Only the muxer can tell (it reads the
    /// E-AC-3 bitstream), so this opens one briefly and looks at the init segment it writes.
    static func detectSpatial(path: String, video: ProbedStream, audio: ProbedStream, segments: [SegmentSpec]) async -> Bool {
        guard audio.codec == "eac3", let first = segments.first,
              let muxer = try? await SegmentMuxer.open(path: path, video: video, audio: audio, segments: [first])
        else { return false }
        defer { muxer.close() }
        return isSpatial(audio, initSegment: muxer.initSegment)
    }

    /// A small standalone MP4 holding the video keyframe at or just before `time`: the engine turns it into a still, because
    /// AVFoundation can't make images from an HLS stream.
    func stillClip(near time: Duration) async throws -> (data: Data, keyframe: Duration) {
        var low = 0, high = probe.keyframes.count
        while low < high {
            let mid = (low + high) / 2
            if probe.keyframes[mid] <= time { low = mid + 1 } else { high = mid }
        }
        let keyframe = probe.keyframes[max(0, low - 1)]
        return (try await muxer.stillClip(at: keyframe), keyframe)
    }

    func stop() {
        server.stop()
        muxer.close()
    }

    // MARK: Descriptions

    static func mediaInfo(probe: MKVProbeResult, video: ProbedStream, audio: ProbedStream?, fileBytes: Int64) -> MediaInfo {
        var info = MediaInfo(container: "MKV", engineName: "AVFoundation (remuxed)")
        info.hdr = video.hdr
        info.videoCodec = displayName(forCodec: video.codec)
        info.audioCodec = audio.map { RemuxSupport.canCopyAudio(codec: $0.codec) ? displayName(forCodec: $0.codec) : "\(displayName(forCodec: $0.codec)) → AAC" }
        info.resolution = CGSize(width: video.width, height: video.height)
        info.displaySize = info.resolution
        info.frameRate = video.frameRate
        info.colorPrimaries = ColorDescription.coreMediaPrimaries(fromFFmpeg: video.colorPrimaries)
        info.transferFunction = ColorDescription.coreMediaTransfer(fromFFmpeg: video.transferFunction)
        if probe.duration.seconds > 0, fileBytes > 0 { info.bitrate = Double(fileBytes) * 8 / probe.duration.seconds }
        info.title = probe.title
        info.chapters = probe.chapters
        return info
    }

    static func mediaTrack(for stream: ProbedStream, isSpatial: Bool) -> MediaTrack {
        MediaTrack(
            id: "audio-\(stream.id)", kind: .audio,
            // Matroska says `eng`; the rest of the app speaks `en`.
            language: stream.language.map(LanguageMatching.primaryLanguage),
            title: stream.title, codec: displayName(forCodec: stream.codec), channels: stream.channels > 0 ? stream.channels : nil,
            isDefault: stream.isDefault, isForced: false, isSpatial: isSpatial
        )
    }

    static func displayName(forCodec codec: String) -> String {
        CodecNames.displayName(forFFmpegCodec: codec)
    }
}

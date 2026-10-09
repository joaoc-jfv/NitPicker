import FFmpegKit
import Foundation

/// Cuts HLS segments out of a media file on demand, copying packets without re-encoding (PLAN.md, phase 2; the design
/// comes from `Spikes/MKVRemux`).
///
/// Each segment is made by seeking the demuxer to its keyframe and writing the packets through a fresh mp4 muxer.
/// Segment 0 also provides the init segment that every segment shares. The muxer rebases each run to zero, so the
/// fragments' `tfdt` is rewritten to the segment's real place on the timeline, measured against that shared init.
///
/// libavformat contexts are not thread-safe, so everything runs on one serial queue. `close` doesn't wait for it: it interrupts the
/// read in progress and lets the queue finish, so the main thread never waits on a cut.
final class SegmentMuxer: @unchecked Sendable {
    enum Failure: Error, Equatable, LocalizedError {
        case cannotOpen(String)
        case cannotCut(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let reason): "This file can't be read: \(reason)"
            case .cannotCut(let reason): "This video can't be prepared for playback: \(reason)"
            }
        }
    }

    let initSegment: [UInt8]

    private let queue = DispatchQueue(label: "nitpicker.segment-muxer", qos: .userInitiated)
    /// Raised by `close`; libavformat polls it during reads.
    private let interrupt = FFmpegInput.Interrupt()
    /// For tests: the serial queue every cut runs on.
    var queueForTesting: DispatchQueue { queue }
    private let segments: [SegmentSpec]
    private let videoIndex: Int
    private let audioIndex: Int?
    /// Set when the audio can't be copied; every cut then converts it to AAC.
    private var transcoder: AudioTranscoder?
    private let origin: Double
    private let initInfo: MP4Boxes.InitInfo
    private var input: UnsafeMutablePointer<AVFormatContext>?
    private var cache: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private var cachedBytes = 0
    private static let cacheLimit = 160 * 1024 * 1024

    /// Opens the file, and cuts segment 0 to get the init segment.
    static func open(path: String, video: ProbedStream, audio: ProbedStream?, segments: [SegmentSpec], transcodeAudio: Bool = false) async throws -> SegmentMuxer {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "nitpicker.segment-muxer.open", qos: .userInitiated).async {
                continuation.resume(with: Result { try SegmentMuxer(path: path, video: video, audio: audio, segments: segments, transcodeAudio: transcodeAudio) })
            }
        }
    }

    private init(path: String, video: ProbedStream, audio: ProbedStream?, segments: [SegmentSpec], transcodeAudio: Bool) throws {
        guard let first = segments.first else { throw Failure.cannotCut("the file has no video keyframes") }
        self.segments = segments
        videoIndex = video.id
        audioIndex = audio?.id
        origin = first.start.seconds

        let context: UnsafeMutablePointer<AVFormatContext>
        do { context = try FFmpegInput.open(path: path, formats: FFmpegInput.remuxFormats, interrupt: interrupt) } catch {
            throw Failure.cannotOpen(Self.message(error.code))
        }
        var opened: UnsafeMutablePointer<AVFormatContext>? = context
        let code = avformat_find_stream_info(context, nil)
        guard code >= 0 else {
            avformat_close_input(&opened)
            throw Failure.cannotOpen(Self.message(code))
        }
        // The streams are the probe's; a file that changed since then may not have them.
        guard video.id < Int(context.pointee.nb_streams), (audio?.id ?? 0) < Int(context.pointee.nb_streams) else {
            avformat_close_input(&opened)
            throw Failure.cannotOpen("the file changed while it was being opened")
        }
        for index in 0..<Int(context.pointee.nb_streams) where index != video.id && index != audio?.id {
            context.pointee.streams[index]?.pointee.discard = AVDISCARD_ALL
        }
        input = context
        if transcodeAudio, let audio {
            do { transcoder = try AudioTranscoder(stream: audio, from: context) } catch {
                avformat_close_input(&input)
                throw error
            }
        }

        // Segment 0 is cut with the same code as every other; its leading boxes are the init segment.
        let cut: Cut
        do { cut = try Self.cut(first, from: context, videoIndex: video.id, audioIndex: audio?.id, transcoder: transcoder) } catch {
            avformat_close_input(&input)
            throw error
        }
        let raw = cut.bytes
        guard let firstFragment = MP4Boxes.children(of: raw).first(where: { $0.type == "moof" }),
              let info = MP4Boxes.initInfo(Array(raw[0..<firstFragment.offset]))
        else {
            avformat_close_input(&input)
            throw Failure.cannotCut("the muxer produced no fragments")
        }
        initSegment = Array(raw[0..<firstFragment.offset])
        initInfo = info
        let fragments = Self.retimed(Array(raw[firstFragment.offset...]), cut: cut, spec: first, origin: origin, info: info)
        remember(Data(fragments), at: 0)
    }

    deinit {
        // `close()` is the normal path; this covers a muxer dropped without it.
        if input != nil { avformat_close_input(&input) }
    }

    /// Returns at once. A cut in progress is interrupted and fails; requests still queued find the file closed.
    func close() {
        interrupt.raise()
        queue.async { [self] in
            if input != nil { avformat_close_input(&input) }
            transcoder?.close()
            transcoder = nil
            cache = [:]
            cacheOrder = []
            cachedBytes = 0
        }
    }

    /// The moof+mdat bytes of segment `index`, ready to serve.
    func segment(_ index: Int) async throws -> Data {
        guard segments.indices.contains(index) else { throw Failure.cannotCut("no segment \(index)") }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { try cutOnQueue(index) })
            }
        }
    }

    /// A complete video-only MP4 that starts at the keyframe `keyframe` and runs a fraction of a second: enough for a still.
    /// It isn't cached, so scrubbing through thumbnails doesn't push playback's segments out.
    func stillClip(at keyframe: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result {
                    guard let input, !interrupt.isRaised else { throw Failure.cannotCut("the file was closed") }
                    let length = Duration.milliseconds(600)
                    let spec = SegmentSpec(index: 0, start: keyframe, end: keyframe + length, duration: length)
                    let bytes = try Self.cut(spec, from: input, videoIndex: videoIndex, audioIndex: nil, transcoder: nil).bytes
                    guard !interrupt.isRaised else { throw Failure.cannotCut("the file was closed") }
                    return Data(bytes)
                })
            }
        }
    }

    private func cutOnQueue(_ index: Int) throws -> Data {
        if let hit = cache[index] {
            cacheOrder.removeAll { $0 == index }
            cacheOrder.append(index)
            return hit
        }
        guard let input, !interrupt.isRaised else { throw Failure.cannotCut("the file was closed") }
        let spec = segments[index]
        let cut = try Self.cut(spec, from: input, videoIndex: videoIndex, audioIndex: audioIndex, transcoder: transcoder)
        // An interrupted read ends the cut early; what it made is incomplete.
        guard !interrupt.isRaised else { throw Failure.cannotCut("the file was closed") }
        let raw = cut.bytes
        guard let firstFragment = MP4Boxes.children(of: raw).first(where: { $0.type == "moof" }) else {
            throw Failure.cannotCut("segment \(index) is empty")
        }
        let fragments = Self.retimed(Array(raw[firstFragment.offset...]), cut: cut, spec: spec, origin: origin, info: initInfo)
        let data = Data(fragments)
        remember(data, at: index)
        return data
    }

    private func remember(_ data: Data, at index: Int) {
        cache[index] = data
        cacheOrder.append(index)
        cachedBytes += data.count
        while cachedBytes > Self.cacheLimit, cacheOrder.count > 1 {
            let oldest = cacheOrder.removeFirst()
            cachedBytes -= cache.removeValue(forKey: oldest)?.count ?? 0
        }
    }

    // MARK: Cutting

    /// The muxer's output, and where its packets really started: what the timestamp rewrite needs.
    private struct Cut {
        var bytes: [UInt8]
        var firstVideoPTS: Double
        var firstAudioPTS: Double?
    }

    /// Seeks to `spec.start` and muxes video and audio up to `spec.end` with a fresh muxer. Returns ftyp, moov and the
    /// fragments, as the muxer wrote them (timestamps rebased to zero).
    private static func cut(_ spec: SegmentSpec, from input: UnsafeMutablePointer<AVFormatContext>, videoIndex: Int, audioIndex: Int?, transcoder: AudioTranscoder?) throws -> Cut {
        let start = spec.start.seconds
        let end = spec.end?.seconds
        let videoStream = input.pointee.streams[videoIndex]!
        let timeBase = videoStream.pointee.time_base
        guard timeBase.num > 0, timeBase.den > 0 else { throw Failure.cannotCut("the video has no usable time base") }
        // Converted audio carries on from the previous segment when this one follows it; after a jump it starts cold.
        if let transcoder, transcoder.resumeTime != spec.start { transcoder.reset() }
        // Half a millisecond past the keyframe, so seeking backwards lands on it and not on the one before.
        let seekTarget = Int64((start + 0.0005) / av_q2d(timeBase))
        guard av_seek_frame(input, Int32(videoIndex), seekTarget, AVSEEK_FLAG_BACKWARD) >= 0 else { throw Failure.cannotCut("seeking failed") }

        var outputRef: UnsafeMutablePointer<AVFormatContext>?
        var code = avformat_alloc_output_context2(&outputRef, nil, "mp4", nil)
        guard code >= 0, let output = outputRef else { throw Failure.cannotCut(message(code)) }
        defer { avformat_free_context(output) }

        var outputIndex: [Int: Int32] = [:]
        for index in [videoIndex] + (audioIndex.map { [$0] } ?? []) {
            let stream = input.pointee.streams[index]!
            guard let out = avformat_new_stream(output, nil) else { throw Failure.cannotCut("out of memory") }
            let converted = index == audioIndex ? transcoder : nil
            code = avcodec_parameters_copy(out.pointee.codecpar, converted?.outputParameters ?? stream.pointee.codecpar)
            guard code >= 0 else { throw Failure.cannotCut(message(code)) }
            let parameters = out.pointee.codecpar!
            parameters.pointee.codec_tag = parameters.pointee.codec_id == AV_CODEC_ID_HEVC ? fourCC("hvc1") : 0
            if parameters.pointee.frame_size == 0 {
                // Matroska doesn't carry frame sizes, and the muxer wants them.
                switch parameters.pointee.codec_id {
                case AV_CODEC_ID_EAC3, AV_CODEC_ID_AC3: parameters.pointee.frame_size = 1536
                case AV_CODEC_ID_AAC: parameters.pointee.frame_size = 1024
                default: break
                }
            }
            av_dict_copy(&out.pointee.metadata, stream.pointee.metadata, 0)
            out.pointee.time_base = converted.map { AVRational(num: 1, den: Int32($0.format.sampleRate)) } ?? stream.pointee.time_base
            outputIndex[index] = out.pointee.index
        }
        // The mp4 muxer only writes the Dolby Vision configuration box (dvcC/dvvC) when strictness is "unofficial".
        output.pointee.strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL

        final class Sink { var bytes: [UInt8] = [] }
        let sink = Sink()
        let ioSize = 1 << 16
        guard let rawBuffer = av_malloc(ioSize) else { throw Failure.cannotCut("out of memory") }
        var io = avio_alloc_context(rawBuffer.assumingMemoryBound(to: UInt8.self), Int32(ioSize), 1, Unmanaged.passUnretained(sink).toOpaque(), nil, { opaque, buffer, size in
            guard let opaque, let buffer else { return -1 }
            Unmanaged<Sink>.fromOpaque(opaque).takeUnretainedValue().bytes.append(contentsOf: UnsafeBufferPointer(start: buffer, count: Int(size)))
            return size
        }, nil)
        guard let ioContext = io else { av_free(rawBuffer); throw Failure.cannotCut("out of memory") }
        defer {
            av_freep(&io!.pointee.buffer)
            avio_context_free(&io)
        }
        output.pointee.pb = ioContext
        output.pointee.flags |= AVFMT_FLAG_CUSTOM_IO

        // frag_keyframe: a fragment per GOP. delay_moov: the E-AC-3 `dec3` box (with its JOC flag) is derived from the
        // first packets, so the moov follows the first fragment.
        var options: OpaquePointer?
        av_dict_set(&options, "movflags", "frag_keyframe+delay_moov+default_base_moof", 0)
        defer { av_dict_free(&options) }
        code = avformat_write_header(output, &options)
        guard code >= 0 else { throw Failure.cannotCut(message(code)) }

        guard let packet = av_packet_alloc() else { throw Failure.cannotCut("out of memory") }
        defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }
        var firstVideo: Double?
        var firstAudio: Double?
        var videoDone = false, audioDone = audioIndex == nil
        let noPTS = Int64.min
        // Writes one AAC packet from the converter, which stamps its packets in 1/sampleRate on the file's own timeline.
        func writeConverted(_ encoded: UnsafeMutablePointer<AVPacket>) throws {
            guard let audioIndex, let mapped = outputIndex[audioIndex], let transcoder else { return }
            if firstAudio == nil { firstAudio = Double(encoded.pointee.pts) / Double(transcoder.format.sampleRate) }
            encoded.pointee.stream_index = mapped
            let timeBase = AVRational(num: 1, den: Int32(transcoder.format.sampleRate))
            av_packet_rescale_ts(encoded, timeBase, output.pointee.streams[Int(mapped)]!.pointee.time_base)
            let code = av_interleaved_write_frame(output, encoded)
            guard code >= 0 else { throw Failure.cannotCut(message(code)) }
        }

        while !(videoDone && audioDone), av_read_frame(input, packet) >= 0 {
            defer { av_packet_unref(packet) }
            let index = Int(packet.pointee.stream_index)
            guard let mapped = outputIndex[index], packet.pointee.pts != noPTS else { continue }
            let stream = input.pointee.streams[index]!
            let time = Double(packet.pointee.pts) * av_q2d(stream.pointee.time_base)
            if index == videoIndex {
                if firstVideo == nil {
                    // Start on the boundary keyframe.
                    guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0, time >= start - 0.001 else { continue }
                    firstVideo = time
                }
                if let end, time >= end - 0.001 { videoDone = true; continue }
            } else {
                if time < start - 0.001 { continue }
                if let end, time >= end - 0.001 { audioDone = true; continue }
                if let transcoder {
                    guard firstVideo != nil else { continue }
                    try transcoder.process(packet, emit: writeConverted)
                    continue
                }
                if firstAudio == nil { firstAudio = time }
            }
            guard firstVideo != nil else { continue }  // audio ahead of the first video keyframe
            packet.pointee.stream_index = mapped
            av_packet_rescale_ts(packet, stream.pointee.time_base, output.pointee.streams[Int(mapped)]!.pointee.time_base)
            code = av_interleaved_write_frame(output, packet)
            guard code >= 0 else { throw Failure.cannotCut(message(code)) }
        }
        if let transcoder {
            // The last segment drains the converter; every other one leaves its state for the segment that follows.
            if end == nil { try transcoder.process(nil, emit: writeConverted) }
            transcoder.resumeTime = spec.end
        }
        code = av_write_trailer(output)
        guard code >= 0 else { throw Failure.cannotCut(message(code)) }
        avio_flush(ioContext)
        guard firstVideo != nil else { throw Failure.cannotCut("no video at \(String(format: "%.1f", start)) s") }
        return Cut(bytes: sink.bytes, firstVideoPTS: firstVideo ?? start, firstAudioPTS: firstAudio)
    }

    /// Rewrites the fragments' timestamps so the first sample of each track lands on `pts - origin`.
    /// presentation = tfdt + composition offset - edit-list media time + empty-edit delay.
    private static func retimed(
        _ fragments: [UInt8], cut: Cut, spec: SegmentSpec, origin: Double, info: MP4Boxes.InitInfo
    ) -> [UInt8] {
        let trackIDs = info.tracks.map(\.trackID)
        var bytes = fragments
        var deltas = Array(repeating: 0, count: info.tracks.count)
        for timing in MP4Boxes.firstFragmentTiming(bytes, trackIDs: trackIDs) {
            let firstPTS = timing.track == 0 ? cut.firstVideoPTS : (cut.firstAudioPTS ?? cut.firstVideoPTS)
            let scale = Double(info.tracks[timing.track].timescale)
            let wanted = Int(((firstPTS - origin) * scale).rounded()) - info.emptyEditTicks(track: timing.track)
                + info.mediaTime(track: timing.track) - timing.firstCompositionOffset
            deltas[timing.track] = max(wanted, 0) - timing.baseDecodeTime
        }
        MP4Boxes.rewrite(&bytes, trackIDs: trackIDs, deltas: deltas, firstSequenceNumber: spec.index * 1000 + 1)
        return bytes
    }

    // MARK: Helpers

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    private static func message(_ code: Int32) -> String { FFmpegInput.message(code) }
}

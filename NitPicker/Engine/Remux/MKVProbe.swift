import FFmpegKit
import Foundation

struct ProbedStream: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case video, audio, subtitle, other }

    /// Index of the stream in the file.
    var id: Int
    var kind: Kind
    /// FFmpeg's codec name: `hevc`, `eac3`, `subrip`, ...
    var codec: String
    /// As the file spells it (Matroska uses ISO 639-2: `eng`, `ita`, `chi`).
    var language: String?
    var title: String?
    var isDefault = false
    var isForced = false

    // Video
    var width = 0
    var height = 0
    var frameRate: Double?
    var hdr: HDRFormat = .sdr
    var colorPrimaries: String?
    var transferFunction: String?

    // Audio
    var channels = 0
    var sampleRate = 0

    var bitRate: Int64 = 0
}

struct MKVProbeResult: Equatable, Sendable {
    /// libavformat's name for the container: `matroska,webm`.
    var formatName: String
    var title: String?
    var duration: Duration
    var streams: [ProbedStream]
    var chapters: [Chapter]
    /// Start of every video keyframe, ascending, read from the container's index (the Matroska Cues).
    /// Empty when the file has no index; the remuxer then has to scan.
    var keyframes: [Duration]

    var video: [ProbedStream] { streams.filter { $0.kind == .video } }
    var audio: [ProbedStream] { streams.filter { $0.kind == .audio } }
    var subtitles: [ProbedStream] { streams.filter { $0.kind == .subtitle } }
}

/// Reads a media file's structure with libavformat, without decoding anything.
enum MKVProbe {
    enum Failure: Error, Equatable, LocalizedError {
        case cannotOpen(String)
        case noStreams

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let reason): "This file can't be read: \(reason)"
            case .noStreams: "This file has no audio or video."
            }
        }
    }

    /// Runs off the calling actor: opening and probing reads from disk.
    static func probe(url: URL) async throws -> MKVProbeResult {
        let path = url.path
        return try await Task.detached(priority: .userInitiated) { try probe(path: path) }.value
    }

    static func probe(path: String) throws -> MKVProbeResult {
        let context = try open(path)
        var opened: UnsafeMutablePointer<AVFormatContext>? = context
        defer { avformat_close_input(&opened) }
        let code = avformat_find_stream_info(context, nil)
        guard code >= 0 else { throw Failure.cannotOpen(message(for: code)) }
        guard context.pointee.nb_streams > 0 else { throw Failure.noStreams }

        var streams: [ProbedStream] = []
        var firstVideo: Int?
        for index in 0..<Int(context.pointee.nb_streams) {
            guard let stream = context.pointee.streams[index] else { continue }
            let probed = describe(stream, index: index, in: context)
            if probed.kind == .video, firstVideo == nil { firstVideo = index }
            streams.append(probed)
        }
        let duration: Duration = context.pointee.duration > 0 ? .seconds(Double(context.pointee.duration) / Double(AV_TIME_BASE)) : .zero
        let keyframes = firstVideo.map { keyframes(of: context, videoIndex: $0) } ?? []
        return MKVProbeResult(
            formatName: String(cString: context.pointee.iformat.pointee.name),
            title: metadata(context.pointee.metadata, "title"),
            duration: duration,
            streams: streams,
            chapters: chapters(of: context),
            keyframes: isCompleteIndex(keyframes, duration: duration) ? keyframes : []
        )
    }

    // MARK: Streams

    private static func describe(_ stream: UnsafeMutablePointer<AVStream>, index: Int, in context: UnsafeMutablePointer<AVFormatContext>) -> ProbedStream {
        let parameters = stream.pointee.codecpar.pointee
        let kind: ProbedStream.Kind = switch parameters.codec_type {
        case AVMEDIA_TYPE_VIDEO: .video
        case AVMEDIA_TYPE_AUDIO: .audio
        case AVMEDIA_TYPE_SUBTITLE: .subtitle
        default: .other
        }
        var result = ProbedStream(
            id: index, kind: kind, codec: String(cString: avcodec_get_name(parameters.codec_id)),
            language: metadata(stream.pointee.metadata, "language").flatMap { $0 == "und" ? nil : $0 },
            title: metadata(stream.pointee.metadata, "title"),
            isDefault: stream.pointee.disposition & AV_DISPOSITION_DEFAULT != 0,
            isForced: stream.pointee.disposition & AV_DISPOSITION_FORCED != 0
        )
        result.bitRate = parameters.bit_rate
        switch kind {
        case .video:
            result.width = Int(parameters.width)
            result.height = Int(parameters.height)
            let rate = av_guess_frame_rate(context, stream, nil)
            result.frameRate = rate.den > 0 && rate.num > 0 ? Double(rate.num) / Double(rate.den) : nil
            result.hdr = hdrFormat(of: parameters)
            result.colorPrimaries = colorName(av_color_primaries_name(parameters.color_primaries))
            result.transferFunction = colorName(av_color_transfer_name(parameters.color_trc))
        case .audio:
            result.channels = Int(parameters.ch_layout.nb_channels)
            result.sampleRate = Int(parameters.sample_rate)
        default: break
        }
        return result
    }

    /// HDR10 and HLG come from the transfer function; Dolby Vision from its configuration record, which
    /// Matroska stores as a block addition mapping (`dvcC`/`dvvC`) and libavformat exposes as codec side data.
    static func hdrFormat(of parameters: AVCodecParameters) -> HDRFormat {
        if let record = av_packet_side_data_get(parameters.coded_side_data, parameters.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
           record.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size {
            let config = UnsafeRawPointer(record.pointee.data).load(as: AVDOVIDecoderConfigurationRecord.self)
            return .dolbyVision(profile: Int(config.dv_profile), compatibilityID: Int(config.dv_bl_signal_compatibility_id))
        }
        switch parameters.color_trc {
        case AVCOL_TRC_SMPTE2084: return .hdr10
        case AVCOL_TRC_ARIB_STD_B67: return .hlg
        default: return .sdr
        }
    }

    // MARK: Chapters and keyframes

    private static func chapters(of context: UnsafeMutablePointer<AVFormatContext>) -> [Chapter] {
        var result: [Chapter] = []
        for index in 0..<Int(context.pointee.nb_chapters) {
            guard let chapter = context.pointee.chapters[index] else { continue }
            guard let seconds = FFmpegTimestamp.seconds(chapter.pointee.start, timeBase: chapter.pointee.time_base) else { continue }
            let title = metadata(chapter.pointee.metadata, "title")
            result.append(Chapter(id: result.count, title: title ?? "Chapter \(result.count + 1)", start: .seconds(max(0, seconds))))
        }
        return result.sorted { $0.start < $1.start }.enumerated().map { Chapter(id: $0.offset, title: $0.element.title, start: $0.element.start) }
    }

    /// The Matroska Cues are parsed lazily, on the first seek, so seek to the start first and then read the index.
    private static func keyframes(of context: UnsafeMutablePointer<AVFormatContext>, videoIndex: Int) -> [Duration] {
        _ = av_seek_frame(context, Int32(videoIndex), 0, AVSEEK_FLAG_BACKWARD)
        guard let stream = context.pointee.streams[videoIndex] else { return [] }
        var times: [Double] = []
        for index in 0..<avformat_index_get_entries_count(stream) {
            guard let entry = avformat_index_get_entry(stream, index), entry.pointee.flags & Int32(AVINDEX_KEYFRAME) != 0,
                  let time = FFmpegTimestamp.seconds(entry.pointee.timestamp, timeBase: stream.pointee.time_base)
            else { continue }
            times.append(time)
        }
        var seen = Set<Int64>()
        return times.sorted().filter { seen.insert(Int64(($0 * 1000).rounded())).inserted }.map { .seconds(max(0, $0)) }
    }

    /// For a file without Cues: reads the whole file once and notes where every video keyframe starts. Slow on a big file
    /// (it has to read all of it), so it is only used when the file has no index of its own. Runs off the calling actor.
    static func scanKeyframes(url: URL, videoIndex: Int) async throws -> [Duration] {
        let path = url.path
        return try await Task.detached(priority: .userInitiated) { try scanKeyframes(path: path, videoIndex: videoIndex) }.value
    }

    static func scanKeyframes(path: String, videoIndex: Int) throws -> [Duration] {
        let context = try open(path)
        var opened: UnsafeMutablePointer<AVFormatContext>? = context
        defer { avformat_close_input(&opened) }
        guard videoIndex < Int(context.pointee.nb_streams), let video = context.pointee.streams[videoIndex] else { return [] }
        for index in 0..<Int(context.pointee.nb_streams) where index != videoIndex { context.pointee.streams[index]?.pointee.discard = AVDISCARD_ALL }
        guard let packet = av_packet_alloc() else { return [] }
        defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }

        var times: [Double] = []
        while av_read_frame(context, packet) >= 0 {
            defer { av_packet_unref(packet) }
            if Task.isCancelled { throw CancellationError() }
            guard Int(packet.pointee.stream_index) == videoIndex, packet.pointee.flags & AV_PKT_FLAG_KEY != 0 else { continue }
            let stamp = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
            if let time = FFmpegTimestamp.seconds(stamp, timeBase: video.pointee.time_base) { times.append(time) }
        }
        var seen = Set<Int64>()
        return times.sorted().filter { seen.insert(Int64(($0 * 1000).rounded())).inserted }.map { .seconds(max(0, $0)) }
    }

    /// Whether `keyframes` really is the file's index and not what probing happened to read from the start.
    /// A real index (the Cues) reaches near the end; a partial one stops after the first few seconds.
    static func isCompleteIndex(_ keyframes: [Duration], duration: Duration) -> Bool {
        guard keyframes.count > 1, let last = keyframes.last else { return false }
        guard duration > .zero else { return true }
        return duration - last <= max(.seconds(30), duration * 0.05)
    }

    // MARK: Helpers

    private static func metadata(_ dictionary: OpaquePointer?, _ key: String) -> String? {
        guard let entry = av_dict_get(dictionary, key, nil, 0), let value = entry.pointee.value else { return nil }
        let text = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func colorName(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        let name = String(cString: pointer)
        return name == "unknown" || name == "unspecified" ? nil : name
    }

    /// Opens `path` for reading: a local file, in one of the containers the remuxer handles.
    static func open(_ path: String) throws -> UnsafeMutablePointer<AVFormatContext> {
        do {
            return try FFmpegInput.open(path: path, formats: FFmpegInput.remuxFormats)
        } catch {
            throw Failure.cannotOpen(message(for: error.code))
        }
    }

    static func message(for code: Int32) -> String { FFmpegInput.message(code) }
}

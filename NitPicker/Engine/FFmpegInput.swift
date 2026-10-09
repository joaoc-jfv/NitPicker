import FFmpegKit
import Foundation

/// Opens media files with libavformat the one way the app should: local files only, so a file can't make libavformat reach
/// further URLs (an HLS manifest or concat list posing as a video), and, where the caller knows what to expect, only the
/// containers on a short list.
enum FFmpegInput {
    /// The containers the remuxer reads. A mislabelled MP4 still opens; a playlist, manifest or concat script doesn't.
    static let remuxFormats = "matroska,webm,mov,mp4"

    struct OpenError: Error {
        var code: Int32
    }

    /// Raised to make libavformat's blocking reads give up early, so a file can be closed while it is being read.
    final class Interrupt: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.withLock { raised = true } }
        var isRaised: Bool { lock.withLock { raised } }
    }

    /// `formats`: the demuxers allowed (`remuxFormats`), or nil for any. `interrupt` must outlive the returned context.
    static func open(path: String, formats: String? = nil, interrupt: Interrupt? = nil) throws(OpenError) -> UnsafeMutablePointer<AVFormatContext> {
        guard let context = avformat_alloc_context() else { throw OpenError(code: -12) }  // ENOMEM
        if let interrupt {
            context.pointee.interrupt_callback = AVIOInterruptCB(
                callback: { opaque in
                    guard let opaque else { return 0 }
                    return Unmanaged<Interrupt>.fromOpaque(opaque).takeUnretainedValue().isRaised ? 1 : 0
                },
                opaque: Unmanaged.passUnretained(interrupt).toOpaque()
            )
        }
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        av_dict_set(&options, "protocol_whitelist", "file", 0)
        if let formats { av_dict_set(&options, "format_whitelist", formats, 0) }
        // On failure libavformat frees the context and sets the pointer to nil.
        var opened: UnsafeMutablePointer<AVFormatContext>? = context
        let code = avformat_open_input(&opened, path, nil, &options)
        guard code >= 0, let opened else { throw OpenError(code: code) }
        return opened
    }

    /// libavformat's text for an error code.
    static func message(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

/// Timestamps read from a file, which may be anything: a crafted file must not turn into a crash when they are converted.
enum FFmpegTimestamp {
    /// About 31 years; nothing playable is longer, and every later conversion (`Duration`, `Int64` milliseconds) fits.
    static let limit: Double = 1_000_000_000

    /// `timestamp` in seconds, or nil when it is missing (`AV_NOPTS_VALUE`), the time base is unusable, or the result is out of range.
    static func seconds(_ timestamp: Int64, timeBase: AVRational) -> Double? {
        guard timestamp != Int64.min, timeBase.num > 0, timeBase.den > 0 else { return nil }
        let value = Double(timestamp) * Double(timeBase.num) / Double(timeBase.den)
        return value.isFinite && abs(value) < limit ? value : nil
    }
}

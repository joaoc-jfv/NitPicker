import FFmpegKit
import Foundation

/// Reads what mpv's properties leave out about the file, using libavformat.
enum MPVSourceProbe {
    /// The HDR format of the file's first video stream, with the Dolby Vision profile its configuration record carries.
    static func hdrFormat(atPath path: String) -> HDRFormat? {
        guard let context = try? FFmpegInput.open(path: path) else { return nil }
        var input: UnsafeMutablePointer<AVFormatContext>? = context
        defer { avformat_close_input(&input) }
        guard avformat_find_stream_info(context, nil) >= 0 else { return nil }
        let index = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard index >= 0, let parameters = context.pointee.streams[Int(index)]?.pointee.codecpar else { return nil }
        return MKVProbe.hdrFormat(of: parameters.pointee)
    }
}

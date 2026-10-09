import CoreGraphics
import FFmpegKit
import Foundation

/// Stills for the scrub preview, the welcome-screen poster and Now Playing artwork when libmpv plays the file. mpv can only
/// capture the frame on screen, so this is a second, independent decode path: libavformat seeks to the keyframe at or before the
/// time, libavcodec decodes that one frame in software, and swscale turns it into a small RGB picture.
///
/// HDR sources come out with their transfer curve unmapped (a dull picture); the preview is a few hundred pixels wide, so the
/// colours are not worth a tone-mapping pass.
final class MPVThumbnailer: @unchecked Sendable {
    /// Lets a caller that stopped waiting tell the decode to stop.
    final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func cancel() { lock.lock(); flag = true; lock.unlock() }
    }

    private static let eof: Int32 = -541478725
    private static let again: Int32 = -35

    private let path: String
    /// Requests run one at a time, off the main thread.
    private let queue = DispatchQueue(label: "nitpicker.mpv-thumbnails", qos: .utility)
    private var format: UnsafeMutablePointer<AVFormatContext>?
    private var decoder: UnsafeMutablePointer<AVCodecContext>?
    private var streamIndex: Int32 = -1
    private var opened = false
    private var failedToOpen = false
    private var closed = false

    init(path: String) {
        self.path = path
    }

    deinit { closeOnQueue() }

    func close() {
        queue.async { [self] in
            closed = true
            closeOnQueue()
        }
    }

    private func closeOnQueue() {
        avcodec_free_context(&decoder)
        if format != nil { avformat_close_input(&format) }
    }

    /// A still from the keyframe at or before `time`, scaled to fit `maxSize`. Nil if the file has no picture there to give.
    func thumbnail(at time: Duration, maxSize: CGSize) async -> CGImage? {
        let ticket = Ticket()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                queue.async { [self] in
                    continuation.resume(returning: still(at: time, maxSize: maxSize, ticket: ticket))
                }
            }
        } onCancel: {
            ticket.cancel()
        }
    }

    // MARK: Decoding

    private func openIfNeeded() -> Bool {
        if opened { return true }
        guard !failedToOpen, !closed else { return false }
        failedToOpen = true
        guard let input = try? FFmpegInput.open(path: path) else { return false }
        format = input
        guard avformat_find_stream_info(input, nil) >= 0 else { return false }
        let index = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard index >= 0, let stream = input.pointee.streams[Int(index)], let parameters = stream.pointee.codecpar,
              // A cover picture in an audio file is no thumbnail of the playback.
              stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0,
              let codec = avcodec_find_decoder(parameters.pointee.codec_id), let context = avcodec_alloc_context3(codec)
        else { return false }
        decoder = context
        guard avcodec_parameters_to_context(context, parameters) >= 0 else { return false }
        context.pointee.pkt_timebase = stream.pointee.time_base
        // Only keyframes are wanted, so the decoder can skip the frames in between.
        context.pointee.skip_frame = AVDISCARD_NONKEY
        context.pointee.skip_loop_filter = AVDISCARD_NONKEY
        guard avcodec_open2(context, codec, nil) >= 0 else { return false }
        streamIndex = index
        opened = true
        failedToOpen = false
        return true
    }

    private func still(at time: Duration, maxSize: CGSize, ticket: Ticket) -> CGImage? {
        guard !ticket.isCancelled, openIfNeeded(), let format, let decoder,
              let stream = format.pointee.streams[Int(streamIndex)]
        else { return nil }
        var target = av_rescale_q(Int64(max(0, time.seconds) * 1_000_000), AVRational(num: 1, den: 1_000_000), stream.pointee.time_base)
        if stream.pointee.start_time != Int64.min { target += stream.pointee.start_time }
        if av_seek_frame(format, streamIndex, target, AVSEEK_FLAG_BACKWARD) < 0 {
            // Some files can't seek backwards from the end; the start still makes a picture.
            guard av_seek_frame(format, streamIndex, stream.pointee.start_time == Int64.min ? 0 : stream.pointee.start_time, AVSEEK_FLAG_BACKWARD) >= 0 else { return nil }
        }
        avcodec_flush_buffers(decoder)

        var packetRef = av_packet_alloc()
        var frameRef = av_frame_alloc()
        defer {
            av_packet_free(&packetRef)
            av_frame_free(&frameRef)
        }
        guard let packet = packetRef, let frame = frameRef else { return nil }

        var sent = 0
        while sent < 120, !ticket.isCancelled {
            let code = av_read_frame(format, packet)
            if code < 0 { break }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == streamIndex else { continue }
            sent += 1
            let sendCode = avcodec_send_packet(decoder, packet)
            if sendCode < 0, sendCode != Self.again { continue }
            if avcodec_receive_frame(decoder, frame) >= 0 { return Self.image(from: frame, maxSize: maxSize) }
        }
        guard !ticket.isCancelled else { return nil }
        // Decoders that work on several frames at once hold the first picture until they are told no more come.
        _ = avcodec_send_packet(decoder, nil)
        if avcodec_receive_frame(decoder, frame) >= 0 { return Self.image(from: frame, maxSize: maxSize) }
        return nil
    }

    // MARK: Conversion

    /// The size a `width`×`height` picture with the given pixel aspect ratio takes to fit `maxSize`, never larger than itself.
    static func fittedSize(width: Int, height: Int, pixelAspect: Double, maxSize: CGSize) -> (width: Int, height: Int) {
        let displayWidth = Double(width) * (pixelAspect > 0 ? pixelAspect : 1)
        let scale = min(1, maxSize.width / displayWidth, maxSize.height / Double(height))
        // Even sizes, because chroma-subsampled sources are happier with them.
        let fittedWidth = max(2, Int((displayWidth * scale / 2).rounded()) * 2)
        let fittedHeight = max(2, Int((Double(height) * scale / 2).rounded()) * 2)
        return (fittedWidth, fittedHeight)
    }

    private static func image(from frame: UnsafeMutablePointer<AVFrame>, maxSize: CGSize) -> CGImage? {
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }
        let aspect = frame.pointee.sample_aspect_ratio
        let pixelAspect = aspect.den > 0 && aspect.num > 0 ? Double(aspect.num) / Double(aspect.den) : 1
        let size = fittedSize(width: width, height: height, pixelAspect: pixelAspect, maxSize: maxSize)

        let source = AVPixelFormat(rawValue: frame.pointee.format)
        guard let scaler = sws_getContext(
            Int32(width), Int32(height), source, Int32(size.width), Int32(size.height), AV_PIX_FMT_RGBA, Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        ) else { return nil }
        defer { sws_freeContext(scaler) }

        // The matrix and range the source declares, so colours keep their place.
        let coefficients: Int32
        switch frame.pointee.colorspace {
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: coefficients = SWS_CS_BT2020
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: coefficients = SWS_CS_ITU601
        default: coefficients = SWS_CS_ITU709
        }
        let sourceFullRange: Int32 = frame.pointee.color_range == AVCOL_RANGE_JPEG ? 1 : 0
        if let table = sws_getCoefficients(coefficients) {
            sws_setColorspaceDetails(scaler, table, sourceFullRange, table, 1, 0, 1 << 16, 1 << 16)
        }

        let bytesPerRow = size.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size.height)
        let converted: Int32 = pixels.withUnsafeMutableBytes { buffer in
            var destination: [UnsafeMutablePointer<UInt8>?] = [buffer.bindMemory(to: UInt8.self).baseAddress, nil, nil, nil]
            var strides: [Int32] = [Int32(bytesPerRow), 0, 0, 0]
            return withUnsafePointer(to: &frame.pointee.data) { dataPointer in
                dataPointer.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { sourceData in
                    withUnsafePointer(to: &frame.pointee.linesize) { linesizePointer in
                        linesizePointer.withMemoryRebound(to: Int32.self, capacity: 8) { sourceStrides in
                            sws_scale(scaler, sourceData, sourceStrides, 0, Int32(height), &destination, &strides)
                        }
                    }
                }
            }
        }
        guard converted == size.height else { return nil }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

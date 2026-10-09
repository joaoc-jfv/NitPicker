import FFmpegKit
import Foundation
import OSLog

/// What the mpv thread tells the engine. Property values are read afresh by the engine when it hears a name; mpv's getters
/// are thread-safe.
enum MPVEvent: Sendable {
    case propertyChanged(String)
    case fileLoaded
    case playbackRestart
    /// `reason` is mpv's `mpv_end_file_reason`; `error` is a message when the file ended because of one.
    case endFile(reason: Int32, error: String?)
    case log(level: String, prefix: String, text: String)
    case shutdown
}

/// A thin Swift face on one `mpv_handle`: options, properties, commands and the event loop. It owns the handle; `destroy`
/// ends it. Everything here may be called from any thread.
final class MPVHandle: @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Events from mpv's own thread, in order. Finishes at shutdown.
    let events: AsyncStream<MPVEvent>
    private let continuation: AsyncStream<MPVEvent>.Continuation
    private var handle: OpaquePointer?
    private let lock = NSLock()
    private var thread: Thread?
    private var isDestroying = false
    /// Signalled when the event thread has returned; mpv can't be destroyed while another thread waits on it.
    private let eventThreadDone = DispatchSemaphore(value: 0)

    /// Creates and initialises an mpv instance. `options` are set before initialisation (some can't change afterwards,
    /// `target-colorspace-hint` among them). `layer` is the `CAMetalLayer` mpv draws into.
    init(layer: AnyObject, options: [(String, String)], logLevel: String = "warn") throws {
        (events, continuation) = AsyncStream.makeStream(of: MPVEvent.self)
        guard let created = mpv_create() else { throw Failure(message: "The compatibility player couldn't start.") }
        handle = created
        var layerAddress = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        var code = mpv_set_option(created, "wid", MPV_FORMAT_INT64, &layerAddress)
        for (name, value) in options where code >= 0 {
            code = mpv_set_option_string(created, name, value)
            if code < 0 { code = 0 }  // an option this build doesn't know isn't fatal
        }
        _ = mpv_request_log_messages(created, logLevel)
        code = mpv_initialize(created)
        guard code >= 0 else {
            mpv_terminate_destroy(created)
            handle = nil
            throw Failure(message: "The compatibility player couldn't start (\(Self.message(code))).")
        }
        // The loop keeps the handle alive while it runs, so `deinit` can't be what ends it: `destroy` is.
        let loop = Thread { [weak self] in self?.runEvents() }
        loop.name = "nitpicker.mpv-events"
        loop.qualityOfService = .userInitiated
        thread = loop
        loop.start()
    }

    deinit { destroy() }

    // MARK: Lifetime

    /// Stops playback and frees the instance. Safe to call twice. It waits for mpv's threads, so the engine calls it off the
    /// main actor.
    func destroy() {
        lock.lock()
        guard !isDestroying, let current = handle else { lock.unlock(); return }
        isDestroying = true
        lock.unlock()
        _ = command(["quit"])
        // With the handle gone the event thread stops at its next turn; the wakeup makes that turn now. Only once the thread
        // has returned is it safe to free the handle, which it may be waiting on.
        lock.lock()
        handle = nil
        lock.unlock()
        mpv_wakeup(current)
        if eventThreadDone.wait(timeout: .now() + 10) == .timedOut {
            // Freeing it now could pull it out from under the thread: leaking one instance is the lesser harm.
            Self.log.error("mpv's event thread didn't stop; leaving the instance alive")
        } else {
            mpv_terminate_destroy(current)
        }
        continuation.finish()
    }

    private func withHandle<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        return body(handle)
    }

    // MARK: Events

    private func runEvents() {
        defer { eventThreadDone.signal() }
        while true {
            // Read the handle without holding the lock across the wait, which `destroy` would deadlock on.
            guard let current = withHandle({ $0 }) else { return }
            guard let event = mpv_wait_event(current, 0.25) else { continue }
            switch event.pointee.event_id {
            case MPV_EVENT_NONE: continue
            case MPV_EVENT_SHUTDOWN:
                continuation.yield(.shutdown)
                return
            case MPV_EVENT_FILE_LOADED: continuation.yield(.fileLoaded)
            case MPV_EVENT_PLAYBACK_RESTART: continuation.yield(.playbackRestart)
            case MPV_EVENT_END_FILE:
                let info = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                let message = info.error < 0 ? Self.message(info.error) : nil
                continuation.yield(.endFile(reason: Int32(info.reason.rawValue), error: message))
            case MPV_EVENT_PROPERTY_CHANGE:
                let property = event.pointee.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                continuation.yield(.propertyChanged(String(cString: property.name)))
            case MPV_EVENT_LOG_MESSAGE:
                let log = event.pointee.data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                continuation.yield(.log(level: String(cString: log.level), prefix: String(cString: log.prefix), text: String(cString: log.text)))
            default: continue
            }
        }
    }

    // MARK: Properties

    /// Asks mpv to report changes of `name` as `.propertyChanged`.
    func observe(_ name: String) {
        _ = withHandle { mpv_observe_property($0, 0, name, MPV_FORMAT_NONE) }
    }

    func string(_ name: String) -> String? {
        withHandle { handle in
            guard let value = mpv_get_property_string(handle, name) else { return nil }
            defer { mpv_free(value) }
            return String(cString: value)
        } ?? nil
    }

    func double(_ name: String) -> Double? {
        withHandle { handle in
            var value = 0.0
            return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
        } ?? nil
    }

    func int(_ name: String) -> Int? {
        withHandle { handle in
            var value: Int64 = 0
            return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? Int(value) : nil
        } ?? nil
    }

    func flag(_ name: String) -> Bool? {
        withHandle { handle in
            var value: Int32 = 0
            return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
        } ?? nil
    }

    @discardableResult
    func set(_ name: String, flag value: Bool) -> Bool {
        withHandle { handle in
            var flag: Int32 = value ? 1 : 0
            return mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag) >= 0
        } ?? false
    }

    @discardableResult
    func set(_ name: String, double value: Double) -> Bool {
        withHandle { handle in
            var number = value
            return mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &number) >= 0
        } ?? false
    }

    /// Returns whether mpv accepted the value.
    @discardableResult
    func set(_ name: String, string value: String) -> Bool {
        withHandle { mpv_set_property_string($0, name, value) >= 0 } ?? false
    }

    // MARK: Commands

    /// Runs a command and waits for it. Returns mpv's error message, or nil on success.
    @discardableResult
    func command(_ parts: [String]) -> String? {
        let code: Int32? = withHandle { handle in
            var arguments: [UnsafePointer<CChar>?] = parts.map { UnsafePointer(strdup($0)) } + [nil]
            defer { for pointer in arguments { if let pointer { free(UnsafeMutablePointer(mutating: pointer)) } } }
            return mpv_command(handle, &arguments)
        }
        guard let code, code < 0 else { return nil }
        return Self.message(code)
    }

    /// One captured frame, 8-bit BGR with an unused fourth byte.
    struct RawFrame {
        var width: Int
        var height: Int
        var stride: Int
        var bytes: [UInt8]
    }

    /// The frame on screen as raw pixels (`flags` is mpv's: `video`, `subtitles`, `window`). This build of FFmpeg has no image
    /// encoders, so `screenshot-to-file` can't be used; the raw command needs none.
    func screenshotRaw(_ flags: String = "video") -> RawFrame? {
        withHandle { handle -> RawFrame? in
            let words = ["screenshot-raw", flags].map { strdup($0) }
            defer { words.forEach { free($0) } }
            var values = words.map { mpv_node(u: .init(string: $0), format: MPV_FORMAT_STRING) }
            var result = mpv_node()
            let code: Int32 = values.withUnsafeMutableBufferPointer { buffer in
                var list = mpv_node_list(num: Int32(buffer.count), values: buffer.baseAddress, keys: nil)
                return withUnsafeMutablePointer(to: &list) { listPointer in
                    var arguments = mpv_node(u: .init(list: listPointer), format: MPV_FORMAT_NODE_ARRAY)
                    return mpv_command_node(handle, &arguments, &result)
                }
            }
            guard code >= 0, result.format == MPV_FORMAT_NODE_MAP, let map = result.u.list else { return nil }
            defer { mpv_free_node_contents(&result) }
            var width = 0, height = 0, stride = 0
            var bytes: [UInt8]?
            for index in 0..<Int(map.pointee.num) {
                guard let key = map.pointee.keys[index].map({ String(cString: $0) }) else { continue }
                let node = map.pointee.values[index]
                switch key {
                case "w": width = Int(node.u.int64)
                case "h": height = Int(node.u.int64)
                case "stride": stride = Int(node.u.int64)
                case "data":
                    if node.format == MPV_FORMAT_BYTE_ARRAY, let array = node.u.ba {
                        bytes = Array(UnsafeBufferPointer(start: array.pointee.data.assumingMemoryBound(to: UInt8.self), count: array.pointee.size))
                    }
                default: break
                }
            }
            // The picture is read as rows of `stride` bytes, so the buffer must really hold them.
            guard let bytes, width > 0, height > 0, stride >= width * 4, bytes.count >= stride * height else { return nil }
            return RawFrame(width: width, height: height, stride: stride, bytes: bytes)
        } ?? nil
    }

    private static let log = Logger(subsystem: "com.joaocadide.nitpicker", category: "mpv")

    static func message(_ code: Int32) -> String {
        String(cString: mpv_error_string(code))
    }
}

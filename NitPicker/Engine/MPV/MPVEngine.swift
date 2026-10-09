import AppKit
import FFmpegKit
import OSLog

/// The compatibility engine (PLAN.md, phase 3): libmpv plays what AVFoundation and the remuxer can't (AVI, VP9, MPEG-4, WMV,
/// FLV, DTS-HD in any container, ...), drawing through Vulkan-on-Metal into an HDR-capable layer. Subtitles, including
/// styled ASS and image formats, are drawn by mpv itself. Dolby Vision plays as tone-mapped HDR here: only AVFoundation
/// does real Dolby Vision.
@MainActor
final class MPVEngine: PlaybackEngine {
    let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let view = MPVVideoView(frame: .zero)
    var videoView: NSView { view }

    private var mpv: MPVHandle?
    private var thumbnailer: MPVThumbnailer?
    private var consuming: Task<Void, Never>?
    private var loadWaiter: CheckedContinuation<Void, any Error>?
    /// Seeks waiting for mpv to show the new position, by seek number.
    private var restartWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var seekCount = 0
    private(set) var lastErrorLog: String?
    private static let log = Logger(subsystem: "com.joaocadide.nitpicker", category: "mpv")

    private var state: PlaybackState = .idle
    private var isLoaded = false
    private var hasStartedPlaying = false
    private var isBuffering = false
    private var lastTimeEmitted: Double?
    private var lastBufferedEmitted: Double?
    private var lastInfo: MediaInfo?
    /// The file's own HDR format, read by libavformat: mpv's properties can't tell Dolby Vision from HDR10.
    private var sourceHDR: HDRFormat?

    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private var trackFields: [MPVMapping.TrackFields] = []

    var preferredAudioLanguage: String?
    /// For tests that read mpv's own properties back.
    var handleForTesting: MPVHandle? { mpv }
    private var storedRate: Float = 1
    private var storedVolume: Float = 1
    private var storedMuted = false
    private var stretches = false
    private var storedAdjustments = VideoAdjustments()
    private var storedSubtitleDelay: Duration = .zero
    private var storedSubtitleStyle = SubtitleStyle()
    private var storedSubtitleLift = 0.06
    /// mpv's track id for each sidecar file already added, so adding one twice reuses the track.
    private var addedSubtitleIDs: [String: Int] = [:]

    private var resizeTask: Task<Void, Never>?
    private var remeasures = 0

    init() {
        (events, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)
        view.onDrawableSizeChange = { [weak self] _ in self?.drawableSizeChanged() }
    }

    let capabilities = EngineCapabilities(supportsPictureInPicture: false, supportsDolbyVision: false, supportsSpatialAudio: false)

    var isHDRPlaybackEligible: Bool {
        (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
    }

    var isPictureInPictureAvailable: Bool { false }
    func togglePictureInPicture() {}

    // MARK: Loading

    func load(_ url: URL, startAt: Duration?) async throws {
        setState(.loading)
        let options = Self.options(hdr: isHDRPlaybackEligible, audioLanguage: preferredAudioLanguage)
        let handle: MPVHandle
        do {
            handle = try MPVHandle(layer: view.metalLayer, options: options)
        } catch {
            let failure = PlaybackError.loadFailed(error.localizedDescription)
            setState(.failed(failure))
            throw failure
        }
        mpv = handle
        thumbnailer = MPVThumbnailer(path: url.path)
        for name in ["time-pos", "duration", "pause", "eof-reached", "paused-for-cache", "track-list", "video-params", "chapter-list", "demuxer-cache-time"] {
            handle.observe(name)
        }
        handle.set("speed", double: Double(storedRate))
        handle.set("volume", double: Double(storedVolume) * 100)
        handle.set("mute", flag: storedMuted)
        handle.set("keepaspect", flag: !stretches)
        handle.set("sub-delay", double: storedSubtitleDelay.seconds)
        applySubtitleStyle(to: handle)
        applyAdjustments(to: handle)
        let stream = handle.events
        consuming = Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }

        var arguments = ["loadfile", url.path, "replace", "-1"]
        if let startAt, startAt > .zero { arguments.append("start=\(startAt.seconds)") }
        let failure: PlaybackError? = await withTaskCancellationHandler {
            do {
                try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                    loadWaiter = waiter
                    if let message = handle.command(arguments) { resumeLoad(with: PlaybackError.loadFailed(Self.friendly(message))) }
                }
                return nil
            } catch let error as PlaybackError {
                return error
            } catch {
                return .loadFailed(error.localizedDescription)
            }
        } onCancel: {
            Task { @MainActor in self.resumeLoad(with: CancellationError()) }
        }
        if let failure {
            setState(.failed(failure))
            throw failure
        }
        try Task.checkCancellation()
    }

    /// The options every instance starts with. `hdr` switches on HDR passthrough, which can't change once mpv is running.
    nonisolated static func options(hdr: Bool, audioLanguage: String?) -> [(String, String)] {
        var options: [(String, String)] = [
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"), ("hwdec", "videotoolbox"),
            ("ytdl", "no"), ("osc", "no"), ("osd-level", "0"), ("input-default-bindings", "no"), ("input-vo-keyboard", "no"),
            ("keep-open", "yes"), ("pause", "yes"), ("sub-auto", "no"), ("audio-display", "no"), ("load-scripts", "no"),
            ("save-position-on-quit", "no"), ("volume-max", "100"), ("target-colorspace-hint", hdr ? "yes" : "no"),
            // A local file must not lead to the network, which the sandbox allows for the loopback server: no following of
            // playlists, EDL or linked files, and libavformat (an HLS manifest posing as a video) opens local files only.
            ("access-references", "no"), ("load-unsafe-playlists", "no"), ("demuxer-lavf-o", "protocol_whitelist=[file]"),
        ]
        if let audioLanguage { options.append(("alang", audioLanguage)) }
        return options
    }

    nonisolated static func friendly(_ mpvMessage: String) -> String {
        mpvMessage.contains("unrecognized file format") ? "This file can't be played." : "This file can't be played (\(mpvMessage))."
    }

    private func resumeLoad(with error: (any Error)?) {
        guard let waiter = loadWaiter else { return }
        loadWaiter = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    func close() {
        resizeTask?.cancel()
        resumeLoad(with: CancellationError())
        consuming?.cancel()
        consuming = nil
        resumeRestartWaiters()
        thumbnailer?.close()
        thumbnailer = nil
        let handle = mpv
        mpv = nil
        // Destroying waits for mpv's threads, one of which may be waiting on the main thread.
        if let handle { Task.detached(priority: .utility) { handle.destroy() } }
        setState(.idle)
        continuation.finish()
    }

    // MARK: Following the window

    /// mpv reads its output size once, when the video output starts: later changes to the layer's size make its swapchain bigger
    /// but leave the picture laid out for the old size (found in the real app, where the window is resized to the video after
    /// the file opens). Restarting the output makes it measure again. That is heavy, so it waits for the size to settle, and the
    /// layer keeps showing the last frame, scaled by Core Animation, until the new one is drawn.
    private func drawableSizeChanged() {
        guard isLoaded else { return }
        scheduleRemeasure()
    }

    private func scheduleRemeasure() {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.remeasureOutput()
        }
    }

    private func remeasureOutput() {
        guard let mpv, isLoaded, let width = mpv.int("osd-dimensions/w"), let height = mpv.int("osd-dimensions/h") else { return }
        let size = view.metalLayer.drawableSize
        guard width > 0, abs(Double(width) - size.width) > 2 || abs(Double(height) - size.height) > 2 else {
            remeasures = 0
            return
        }
        // A size mpv keeps reporting wrongly must not loop.
        guard remeasures < 3 else { return }
        remeasures += 1
        Self.log.debug("restarting the video output: \(width)x\(height) -> \(Int(size.width))x\(Int(size.height))")
        guard let track = mpv.int("vid") else { return }
        mpv.set("vid", string: "no")
        mpv.set("vid", string: "\(track)")
    }

    // MARK: Events

    private func handle(_ event: MPVEvent) {
        switch event {
        case .fileLoaded:
            isLoaded = true
            refreshTracks()
            refreshMediaInfo()
            probeSourceHDR()
            // The video output may have started before the view had its size (it then measures 1×1).
            scheduleRemeasure()
            if let duration = mpv?.double("duration"), duration > 0 { emit(.durationChanged(.seconds(duration))) }
            refreshState()
            resumeLoad(with: nil)
        case .playbackRestart:
            if remeasures == 0 { scheduleRemeasure() }
            emitTime(force: true)
            resumeRestartWaiters()
            refreshState()
        case .endFile(let reason, let message):
            // 4 is an error. Other reasons are a stop we asked for, or the end of a file that keep-open already handled.
            if reason == Int32(MPV_END_FILE_REASON_ERROR.rawValue) {
                let text = message.map(Self.friendly) ?? lastErrorLog ?? "This file can't be played."
                if isLoaded {
                    setState(.failed(.loadFailed(text)))
                } else {
                    resumeLoad(with: PlaybackError.loadFailed(text))
                }
            }
        case .propertyChanged(let name):
            propertyChanged(name)
        case .log(let level, let prefix, let text):
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if level == "error" || level == "fatal" {
                lastErrorLog = line
                Self.log.error("\(prefix, privacy: .public): \(line, privacy: .public)")
            } else {
                Self.log.debug("\(prefix, privacy: .public): \(line, privacy: .public)")
            }
        case .shutdown:
            break
        }
    }

    private func propertyChanged(_ name: String) {
        guard isLoaded || name == "pause" else { return }
        switch name {
        case "time-pos": emitTime(force: false)
        case "duration":
            if let duration = mpv?.double("duration"), duration > 0 { emit(.durationChanged(.seconds(duration))) }
        case "pause", "eof-reached", "paused-for-cache": refreshState()
        case "track-list": refreshTracks()
        case "video-params", "chapter-list": refreshMediaInfo()
        case "demuxer-cache-time":
            if let end = mpv?.double("demuxer-cache-time"), end > 0, abs(end - (lastBufferedEmitted ?? -10)) >= 1 {
                lastBufferedEmitted = end
                emit(.bufferedChanged(.seconds(end)))
            }
        default: break
        }
    }

    private func emitTime(force: Bool) {
        guard let time = mpv?.double("time-pos") else { return }
        // mpv reports every frame; the model wants about four a second.
        if !force, let last = lastTimeEmitted, abs(time - last) < 0.25 { return }
        lastTimeEmitted = time
        emit(.timeChanged(.seconds(max(0, time))))
    }

    private func refreshState() {
        guard let mpv, isLoaded else { return }
        let ended = mpv.flag("eof-reached") ?? false
        let paused = mpv.flag("pause") ?? true
        let caching = mpv.flag("paused-for-cache") ?? false
        let newState: PlaybackState
        if ended {
            newState = .ended
        } else if paused {
            newState = hasStartedPlaying ? .paused : .ready
        } else {
            hasStartedPlaying = true
            newState = .playing
        }
        setState(newState)
        let buffering = caching && !paused
        if buffering != isBuffering {
            isBuffering = buffering
            emit(.bufferingChanged(buffering))
        }
    }

    private func setState(_ newState: PlaybackState) {
        guard newState != state else { return }
        state = newState
        emit(.stateChanged(newState))
    }

    private func emit(_ event: PlaybackEvent) { continuation.yield(event) }

    // MARK: Transport

    func play() {
        guard let mpv, isLoaded else { return }
        if mpv.flag("eof-reached") == true { mpv.command(["seek", "0", "absolute+exact"]) }
        mpv.set("pause", flag: false)
    }

    func pause() {
        mpv?.set("pause", flag: true)
    }

    func seek(to time: Duration, precise: Bool) async {
        guard let mpv, isLoaded else { return }
        let mode = precise ? "absolute+exact" : "absolute+keyframes"
        seekCount += 1
        let seek = seekCount
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            restartWaiters[seek] = waiter
            if mpv.command(["seek", "\(max(0, time.seconds))", mode]) != nil { resumeRestartWaiter(seek) }
            // A seek that never reports back (past the end, say) must not hang the caller. Only this seek: a later one
            // still waits for its own restart.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.resumeRestartWaiter(seek)
            }
        }
        emitTime(force: true)
    }

    private func resumeRestartWaiters() {
        let waiting = restartWaiters
        restartWaiters = [:]
        waiting.values.forEach { $0.resume() }
    }

    private func resumeRestartWaiter(_ seek: Int) {
        restartWaiters.removeValue(forKey: seek)?.resume()
    }

    func step(frames: Int) {
        mpv?.command([frames >= 0 ? "frame-step" : "frame-back-step"])
    }

    var currentTime: Duration { mpv?.double("time-pos").map { .seconds(max(0, $0)) } ?? .zero }

    var rate: Float {
        get { storedRate }
        set { storedRate = newValue; mpv?.set("speed", double: Double(newValue)) }
    }

    var volume: Float {
        get { storedVolume }
        set { storedVolume = newValue; mpv?.set("volume", double: Double(newValue) * 100) }
    }

    var isMuted: Bool {
        get { storedMuted }
        set { storedMuted = newValue; mpv?.set("mute", flag: newValue) }
    }

    var stretchesVideoToFrame: Bool {
        get { stretches }
        set { stretches = newValue; mpv?.set("keepaspect", flag: !newValue) }
    }

    /// Plain downmix for Stereo; the file's own layout otherwise.
    var audioOutputMode: AudioOutputMode = .spatial {
        didSet { mpv?.set("audio-channels", string: audioOutputMode == .stereo ? "stereo" : "auto-safe") }
    }

    /// The frame on screen as mpv shows it (tone-mapped for HDR, so an ordinary picture).
    func captureFrame() async -> CapturedFrame? {
        guard let handle = mpv, isLoaded else { return nil }
        // Off the main actor: copying a 4K frame out takes a moment, and mpv's own threads may want the main thread meanwhile.
        let frame = await Task.detached(priority: .userInitiated) { handle.screenshotRaw("video") }.value
        guard let frame, let provider = CGDataProvider(data: Data(frame.bytes) as CFData) else { return nil }
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
        return CGImage(
            width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.stride,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ).map { .sdr($0) }
    }

    /// mpv can only capture the frame on screen, so stills come from a second decode path (see `MPVThumbnailer`).
    func thumbnail(at time: Duration, maxSize: CGSize) async -> CGImage? {
        await thumbnailer?.thumbnail(at: time, maxSize: maxSize)
    }

    // MARK: Picture adjustments

    var supportsVideoAdjustments: Bool { true }

    func setVideoAdjustments(_ adjustments: VideoAdjustments) {
        storedAdjustments = adjustments.clamped()
        if let mpv { applyAdjustments(to: mpv) }
    }

    private func applyAdjustments(to handle: MPVHandle) {
        for (name, value) in storedAdjustments.mpvProperties { handle.set(name, double: value) }
    }

    // MARK: Subtitles

    var drawsSubtitlesNatively: Bool { true }
    var isCompatibilityEngine: Bool { true }

    func setSubtitleDelay(_ delay: Duration) {
        storedSubtitleDelay = delay
        mpv?.set("sub-delay", double: delay.seconds)
    }

    func setSubtitleStyle(_ style: SubtitleStyle) {
        storedSubtitleStyle = style
        if let mpv { applySubtitleStyle(to: mpv) }
    }

    func setSubtitleLift(_ fraction: Double) {
        storedSubtitleLift = fraction
        mpv?.set("sub-pos", string: "\(MPVMapping.subtitlePosition(lift: fraction))")
    }

    private func applySubtitleStyle(to handle: MPVHandle) {
        for (name, value) in MPVMapping.subtitleProperties(for: storedSubtitleStyle) { handle.set(name, string: value) }
        handle.set("sub-pos", string: "\(MPVMapping.subtitlePosition(lift: storedSubtitleLift))")
    }

    func addExternalSubtitle(_ url: URL, title: String?, language: String?) -> MediaTrack? {
        guard let mpv, isLoaded else { return nil }
        if let id = addedSubtitleIDs[url.path], let existing = subtitleTracks.first(where: { MPVMapping.mpvID(of: $0) == id }) { return existing }
        let known = Set(trackFields.filter { $0.type == "sub" }.map(\.id))
        // "auto" adds the track without choosing it (the app picks by the user's language); a new entry for every call.
        var arguments = ["sub-add", url.path, "auto", title ?? url.deletingPathExtension().lastPathComponent]
        if let language { arguments.append(language) }
        if mpv.command(arguments) != nil { return nil }
        refreshTracks()
        guard let added = trackFields.last(where: { $0.type == "sub" && !known.contains($0.id) }) else { return nil }
        addedSubtitleIDs[url.path] = added.id
        return MPVMapping.mediaTrack(added)
    }

    // MARK: Tracks

    var selectedAudioTrack: MediaTrack? {
        trackFields.first { $0.type == "audio" && $0.isSelected }.flatMap(MPVMapping.mediaTrack)
    }

    var selectedSubtitleTrack: MediaTrack? {
        trackFields.first { $0.type == "sub" && $0.isSelected }.flatMap(MPVMapping.mediaTrack)
    }

    func selectAudio(_ track: MediaTrack?) {
        select(track, property: "aid")
    }

    func selectSubtitle(_ track: MediaTrack?) {
        select(track, property: "sid")
    }

    private func select(_ track: MediaTrack?, property: String) {
        guard let mpv else { return }
        if let track, let id = MPVMapping.mpvID(of: track) {
            mpv.set(property, string: "\(id)")
        } else {
            mpv.set(property, string: "no")
        }
        // mpv reports the new selection through `track-list`, but the model reads it right away.
        refreshTracks()
    }

    private func refreshTracks() {
        guard let mpv else { return }
        let count = mpv.int("track-list/count") ?? 0
        var fields: [MPVMapping.TrackFields] = []
        for index in 0..<count {
            let key = "track-list/\(index)"
            guard let id = mpv.int("\(key)/id"), let type = mpv.string("\(key)/type") else { continue }
            fields.append(MPVMapping.TrackFields(
                id: id, type: type, language: mpv.string("\(key)/lang"), title: mpv.string("\(key)/title"),
                codec: mpv.string("\(key)/codec"), codecProfile: mpv.string("\(key)/codec-profile"),
                channels: mpv.int("\(key)/demux-channel-count"),
                isDefault: mpv.flag("\(key)/default") ?? false, isForced: mpv.flag("\(key)/forced") ?? false,
                isSelected: mpv.flag("\(key)/selected") ?? false, isExternal: mpv.flag("\(key)/external") ?? false
            ))
        }
        guard fields != trackFields else { return }
        trackFields = fields
        audioTracks = fields.filter { $0.type == "audio" }.compactMap(MPVMapping.mediaTrack)
        subtitleTracks = fields.filter { $0.type == "sub" }.compactMap(MPVMapping.mediaTrack)
        emit(.tracksChanged)
    }

    // MARK: Media info

    private func probeSourceHDR() {
        guard let path = mpv?.string("path") else { return }
        Task { [weak self] in
            let format = await Task.detached(priority: .utility) { MPVSourceProbe.hdrFormat(atPath: path) }.value
            guard let self, mpv != nil, let format, format != sourceHDR else { return }
            sourceHDR = format
            refreshMediaInfo()
        }
    }

    private func refreshMediaInfo() {
        guard let mpv, isLoaded else { return }
        var info = MediaInfo(container: MPVMapping.containerName(mpv.string("file-format")), engineName: "mpv (compatibility mode)")
        info.videoCodec = mpv.string("video-format").map(CodecNames.displayName(forFFmpegCodec:))
        info.audioCodec = mpv.string("audio-codec-name").map(CodecNames.displayName(forFFmpegCodec:))
        if let width = mpv.int("video-params/w"), let height = mpv.int("video-params/h") {
            info.resolution = CGSize(width: width, height: height)
            if let displayWidth = mpv.int("video-params/dw"), let displayHeight = mpv.int("video-params/dh") {
                info.displaySize = CGSize(width: displayWidth, height: displayHeight)
            } else {
                info.displaySize = info.resolution
            }
        }
        info.frameRate = mpv.double("container-fps") ?? mpv.double("estimated-vf-fps")
        let gamma = mpv.string("video-params/gamma")
        info.hdr = MPVMapping.hdr(gamma: gamma)
        info.hdrNote = MPVMapping.hdrNote(source: sourceHDR, shown: info.hdr)
        info.colorPrimaries = ColorDescription.coreMediaPrimaries(fromFFmpeg: MPVMapping.ffmpegPrimaries(mpv.string("video-params/primaries")))
        info.transferFunction = ColorDescription.coreMediaTransfer(fromFFmpeg: MPVMapping.ffmpegTransfer(gamma))
        if let duration = mpv.double("duration"), duration > 0, let size = mpv.double("file-size") ?? mpv.double("stream-end") {
            info.bitrate = size * 8 / duration
        }
        info.title = mpv.string("metadata/by-key/title")
        let chapters = mpv.int("chapter-list/count") ?? 0
        info.chapters = (0..<chapters).compactMap { index in
            guard let start = mpv.double("chapter-list/\(index)/time") else { return nil }
            return Chapter(id: index, title: mpv.string("chapter-list/\(index)/title") ?? "Chapter \(index + 1)", start: .seconds(max(0, start)))
        }
        guard info != lastInfo else { return }
        lastInfo = info
        emit(.mediaInfoChanged(info))
    }
}

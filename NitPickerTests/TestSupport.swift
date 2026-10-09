import Testing
import AppKit
import Foundation
@testable import NitPicker

@MainActor
final class FakeSleepPrevention: SleepPrevention {
    private(set) var isActive = false
    func setActive(_ active: Bool) { isActive = active }
}

@MainActor
extension PlayerServices {
    /// Services that touch nothing outside the test: throwaway defaults, no system Now Playing, no sleep assertion.
    static func testing(
        preferences: Preferences = TestPreferences.make(),
        nowPlaying: NullNowPlaying = NullNowPlaying(),
        sleep: FakeSleepPrevention = FakeSleepPrevention(),
        resume: ResumeStore = ResumeStore(defaults: throwawayDefaults()),
        recents: RecentFiles = RecentFiles(defaults: throwawayDefaults()),
        thumbnails: ThumbnailCache = ThumbnailCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-posters-\(UUID().uuidString)")
        ),
        screenshots: ScreenshotStore = ScreenshotStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-shots-\(UUID().uuidString)")
        )
    ) -> PlayerServices {
        PlayerServices(
            preferences: preferences, folderAccess: FolderAccess(defaults: throwawayDefaults()),
            nowPlaying: nowPlaying, resume: resume, recents: recents, sleep: sleep, thumbnails: thumbnails, screenshots: screenshots
        )
    }
}

func throwawayDefaults() -> UserDefaults {
    UserDefaults(suiteName: "nitpicker-tests-\(UUID().uuidString)")!
}

/// A scripted engine: tests push events and read back what the model asked for.
@MainActor
final class FakeEngine: PlaybackEngine {
    let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation

    let videoView = NSView()
    var info = MediaInfo(container: "MP4", engineName: "Fake")
    var duration: Duration = .seconds(1000)
    var currentTime: Duration = .zero
    var isPictureInPictureAvailable = true
    var isHDRPlaybackEligible = true
    private(set) var thumbnailRequests: [Duration] = []
    private(set) var isPlaying = false
    private(set) var seeks: [Duration] = []
    private(set) var closed = false
    private(set) var pictureInPictureToggles = 0
    var thumbnailImage: CGImage?

    var rate: Float = 1
    var volume: Float = 1
    var isMuted = false
    var stretchesVideoToFrame = false
    var audioOutputMode: AudioOutputMode = .spatial
    var preferredAudioLanguage: String?
    let capabilities = EngineCapabilities(supportsPictureInPicture: true, supportsDolbyVision: false, supportsSpatialAudio: false)
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var selectedAudioTrack: MediaTrack?
    var selectedSubtitleTrack: MediaTrack?
    var drawsSubtitlesNatively = false
    var isCompatibilityEngine = false
    var supportsVideoAdjustments = false
    var capturedFrame: CapturedFrame?
    func captureFrame() async -> CapturedFrame? { capturedFrame }
    private(set) var adjustments: [VideoAdjustments] = []
    private(set) var loadedStarts: [Duration?] = []
    private(set) var subtitleDelays: [Duration] = []
    private(set) var subtitleStyles: [SubtitleStyle] = []
    private(set) var subtitleLifts: [Double] = []
    private(set) var addedSubtitleFiles: [URL] = []

    init() {
        (events, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)
    }

    func emit(_ event: PlaybackEvent) { continuation.yield(event) }

    /// Moves the playhead and tells the model.
    func advance(to time: Duration) {
        currentTime = time
        emit(.timeChanged(time))
    }

    /// When set, `load` throws it (an engine that refuses the file).
    var loadError: (any Error)?
    private(set) var loadedURLs: [URL] = []

    /// When set, `load` waits for `releaseLoad()` before it finishes (a slow file).
    var holdsLoad = false
    private var heldLoad: CheckedContinuation<Void, Never>?
    var isHoldingLoad: Bool { heldLoad != nil }
    func releaseLoad() {
        heldLoad?.resume()
        heldLoad = nil
    }

    func load(_ url: URL, startAt: Duration?) async throws {
        loadedURLs.append(url)
        loadedStarts.append(startAt)
        if holdsLoad { await withCheckedContinuation { heldLoad = $0 } }
        if let loadError { throw loadError }
        emit(.durationChanged(duration))
        emit(.mediaInfoChanged(info))
        emit(.tracksChanged)
        emit(.stateChanged(.ready))
    }

    func play() { isPlaying = true; emit(.stateChanged(.playing)) }
    func pause() { isPlaying = false; emit(.stateChanged(.paused)) }
    func seek(to time: Duration, precise: Bool) async { seeks.append(time); advance(to: time) }
    func step(frames: Int) {}
    func setVideoAdjustments(_ value: VideoAdjustments) { adjustments.append(value) }
    func setSubtitleDelay(_ delay: Duration) { subtitleDelays.append(delay) }
    func setSubtitleStyle(_ style: SubtitleStyle) { subtitleStyles.append(style) }
    func setSubtitleLift(_ fraction: Double) { subtitleLifts.append(fraction) }
    func addExternalSubtitle(_ url: URL, title: String?, language: String?) -> MediaTrack? {
        guard drawsSubtitlesNatively else { return nil }
        addedSubtitleFiles.append(url)
        let track = MediaTrack(
            id: "subtitle-\(100 + addedSubtitleFiles.count)", kind: .subtitle, language: language, title: title, codec: "ASS",
            channels: nil, isDefault: false, isForced: false, isSpatial: false
        )
        subtitleTracks.append(track)
        emit(.tracksChanged)
        return track
    }
    func selectAudio(_ track: MediaTrack?) { selectedAudioTrack = track }
    func selectSubtitle(_ track: MediaTrack?) { selectedSubtitleTrack = track }
    /// How long each still takes; the wait doesn't end early when the caller is cancelled (like a decode in progress).
    var thumbnailDelay: Duration?

    func thumbnail(at time: Duration, maxSize: CGSize) async -> CGImage? {
        thumbnailRequests.append(time)
        if let thumbnailDelay { await Task.detached { try? await Task.sleep(for: thumbnailDelay) }.value }
        return thumbnailImage
    }
    func togglePictureInPicture() {
        pictureInPictureToggles += 1
        emit(.pictureInPictureChanged(pictureInPictureToggles % 2 == 1))
    }
    func close() { closed = true; continuation.finish() }
}

@MainActor
func waitUntil(_ what: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

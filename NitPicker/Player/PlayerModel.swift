import AppKit
import Observation

typealias EngineFactory = @MainActor (URL) throws -> any PlaybackEngine

/// UI-facing playback state. The UI talks only to this type; engines stay behind it.
@MainActor
@Observable
final class PlayerModel {
    private(set) var state: PlaybackState = .idle
    private(set) var currentURL: URL?
    private(set) var currentTime: Duration = .zero
    private(set) var duration: Duration = .zero
    private(set) var buffered: Duration = .zero
    private(set) var isBuffering = false
    private(set) var mediaInfo: MediaInfo?
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var selectedAudio: MediaTrack?
    private(set) var selectedSubtitle: MediaTrack?
    private(set) var videoView: NSView?
    private(set) var videoLayout = VideoLayout()

    private(set) var rate: Float = 1
    private(set) var volume: Float = 1
    private(set) var isMuted = false
    private(set) var audioOutputMode: AudioOutputMode

    // UI-only state
    private(set) var activePanel: PlayerPanel?
    private(set) var controlsVisible = true
    private(set) var isPointerOverControls = false
    private(set) var toast: Toast?
    private(set) var resumeOffer: ResumeOffer?
    private(set) var isPictureInPictureAvailable = false
    private(set) var isPictureInPictureActive = false
    private(set) var isHDRPlaybackEligible = false
    private(set) var showsInfoPanel = false
    /// The videos next to the open file, when the folder can be read.
    private(set) var playlist: FolderPlaylist?
    /// The next episode, offered during the last seconds of an episode.
    private(set) var upNext: UpNext?
    private(set) var autoplaysNextEpisode: Bool
    /// Brightness, contrast and saturation, for the open file; only the compatibility engine applies them.
    private(set) var videoAdjustments = VideoAdjustments()
    private(set) var supportsVideoAdjustments = false
    private(set) var cropsBlackBarsAutomatically: Bool
    private(set) var isDetectingBlackBars = false
    /// The file the last screenshot was saved to.
    private(set) var lastScreenshot: URL?
    /// The open file plays on libmpv (see `PlaybackEngine.isCompatibilityEngine`).
    private(set) var isCompatibilityEngine = false
    /// The engine draws subtitles itself (mpv), so the delay and the lift above the controls go to it.
    private(set) var enginePaintsSubtitles = false
    private(set) var scrubPreview: ScrubPreview?
    /// False once the engine has answered a thumbnail request with nothing (the engine has no picture to give),
    /// so the scrub preview shows just the time instead of an empty box.
    private(set) var scrubThumbnailsAvailable = true

    var chapters: [Chapter] { mediaInfo?.chapters ?? [] }
    var currentChapter: Chapter? {
        ChapterNavigation.index(at: currentTime, in: chapters).map { chapters[$0] }
    }

    /// The file's title metadata, else its file name.
    var displayTitle: String {
        mediaInfo?.title ?? currentURL?.deletingPathExtension().lastPathComponent ?? "Nit Picker"
    }

    var recentFiles: RecentFiles { services.recents }

    /// The HUD pill: `["4K", "HDR10", "Spatial Audio"]`.
    var formatBadges: [String] {
        mediaInfo?.formatBadges(spatialAudio: selectedAudio?.isSpatial == true && audioOutputMode == .spatial) ?? []
    }

    var infoSections: [InfoSection] {
        guard let info = mediaInfo else { return [] }
        return InfoSections.build(
            fileName: currentURL?.lastPathComponent ?? displayTitle, info: info, audio: selectedAudio,
            outputMode: audioOutputMode, isHDRPlaybackEligible: isHDRPlaybackEligible, rate: rate,
            spatialAudioAvailable: !isCompatibilityEngine
        )
    }

    var isPlaying: Bool { state == .playing }
    /// Loading the file, or waiting for data while playing.
    var isBusy: Bool { state == .loading || isBuffering }
    var hasMedia: Bool { currentURL != nil }
    var errorMessage: String? {
        if case .failed(let error) = state { error.localizedDescription } else { nil }
    }

    /// Sidecar subtitle tracks, delay and style. Embedded tracks stay on the engine.
    let subtitles: SubtitleTrackStore

    @ObservationIgnored private let services: PlayerServices
    @ObservationIgnored private let engineFactory: EngineFactory
    @ObservationIgnored private let compatibilityFactory: EngineFactory
    @ObservationIgnored private var preferences: Preferences { services.preferences }
    @ObservationIgnored private var folderAccess: FolderAccess { services.folderAccess }
    @ObservationIgnored private var resumeOfferTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var lastResumeSave: ContinuousClock.Instant?
    @ObservationIgnored private var scrubTask: Task<Void, Never>?
    @ObservationIgnored private var scrubThumbnails: [Int: CGImage] = [:]
    @ObservationIgnored private var sidecarTask: Task<Void, Never>?
    @ObservationIgnored private var engine: (any PlaybackEngine)?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    /// Bumped by every open and close, so an open that was overtaken can tell it no longer owns the engine.
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var folderScope: URL?
    @ObservationIgnored private var dismissedUpNext: URL?
    @ObservationIgnored private var playlistTask: Task<Void, Never>?
    @ObservationIgnored private var blackBarTask: Task<Void, Never>?
    /// Bumped by every black-bar run and teardown, so only the latest run clears `isDetectingBlackBars`.
    @ObservationIgnored private var blackBarRun = 0
    /// How long before the end the "Up next" card shows.
    @ObservationIgnored var upNextLeadTime: Duration = .seconds(15)
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivity = ContinuousClock.now

    /// How long the controls stay up without mouse or keyboard activity while playing.
    @ObservationIgnored var autoHideDelay: Duration = .seconds(2.5)
    @ObservationIgnored var toastDuration: Duration = .seconds(1.2)
    /// How often playback progress is saved for resuming.
    @ObservationIgnored var resumeSaveInterval: Duration = .seconds(5)
    @ObservationIgnored var resumeOfferDuration: Duration = .seconds(6)

    init(
        services: PlayerServices = .live(),
        engineFactory: @escaping EngineFactory = EngineRouter.engine(for:),
        compatibilityFactory: @escaping EngineFactory = EngineRouter.compatibilityEngine(for:)
    ) {
        self.services = services
        self.engineFactory = engineFactory
        self.compatibilityFactory = compatibilityFactory
        subtitles = SubtitleTrackStore(preferences: services.preferences, folderAccess: services.folderAccess)
        audioOutputMode = services.preferences.audioOutputMode
        autoplaysNextEpisode = services.preferences.autoplaysNextEpisode
        cropsBlackBarsAutomatically = services.preferences.cropsBlackBarsAutomatically
        services.nowPlaying.handlers = NowPlayingHandlers(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlayPause() },
            skip: { [weak self] seconds in self?.skip(by: .seconds(seconds)) },
            seek: { [weak self] seconds in self?.seek(to: .seconds(seconds), precise: true) }
        )
    }

    // MARK: Opening

    /// Whether `url` is something the user can hand the player (a drop, Finder): a local file, not a web link or a folder.
    nonisolated static func canOpen(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
    }

    func open(_ url: URL, startAt: Duration? = nil, compatibility: Bool = false) {
        openTask?.cancel()
        openTask = Task { await performOpen(url, startAt: startAt, compatibility: compatibility) }
    }

    /// Reopens the file on the other engine at the same place: libmpv for a file the main engines play, and back.
    func toggleCompatibilityEngine() {
        guard let url = currentURL else { return }
        open(url, startAt: currentTime, compatibility: !isCompatibilityEngine)
    }

    func close() {
        openTask?.cancel()
        openGeneration += 1
        teardown()
        currentURL = nil
    }

    private func performOpen(_ url: URL, startAt: Duration?, compatibility: Bool) async {
        openGeneration += 1
        let generation = openGeneration
        teardown()
        currentURL = url
        state = .loading
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        // Held while the file is open, so the folder can be listed and the next file opened.
        folderScope = folderAccess.beginAccess(toFolderContaining: url)

        do {
            var engine = try (compatibility || preferences.forcesCompatibilityEngine) ? compatibilityFactory(url) : engineFactory(url)
            attach(engine)
            do {
                try await engine.load(url, startAt: startAt)
            } catch let error as PlaybackError where error.wantsCompatibilityEngine {
                // A newer open (or a close) has taken over; the engine in use is no longer this file's.
                guard !Task.isCancelled, generation == openGeneration else { throw CancellationError() }
                // The first engine can't play this file; libmpv may be able to.
                discardEngine()
                engine = try compatibilityFactory(url)
                attach(engine)
                try await engine.load(url, startAt: startAt)
            }
            try Task.checkCancellation()
            guard generation == openGeneration else { throw CancellationError() }
            applyTrackPreferences(to: engine)
            engine.play()
            services.recents.note(url)
            if startAt == nil { offerResume(for: url) }
            loadSidecarSubtitles(for: url)
            loadArtwork(from: engine)
            if cropsBlackBarsAutomatically {
                // Once the first seconds are playing and the duration is known.
                blackBarTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled, currentURL == url else { return }
                    detectBlackBars(announce: false)
                }
            }
        } catch is CancellationError {
            // Superseded by another open().
        } catch {
            // The engine reports its own failures through events; this covers the router.
            if !Task.isCancelled, case .loading = state {
                state = .failed(error as? PlaybackError ?? .loadFailed(error.localizedDescription))
            }
        }
    }

    private func attach(_ engine: any PlaybackEngine) {
        self.engine = engine
        videoView = engine.videoView
        engine.rate = rate
        engine.volume = volume
        engine.isMuted = isMuted
        engine.audioOutputMode = audioOutputMode
        engine.preferredAudioLanguage = preferences.audioLanguage
        engine.stretchesVideoToFrame = videoLayout.aspect != .auto
        enginePaintsSubtitles = engine.drawsSubtitlesNatively
        isCompatibilityEngine = engine.isCompatibilityEngine
        supportsVideoAdjustments = engine.supportsVideoAdjustments
        engine.setVideoAdjustments(videoAdjustments)
        engine.setSubtitleStyle(subtitles.style)
        engine.setSubtitleDelay(subtitles.delay)
        isPictureInPictureAvailable = engine.isPictureInPictureAvailable
        isHDRPlaybackEligible = engine.isHDRPlaybackEligible
        eventTask = Task { [weak self] in
            for await event in engine.events {
                self?.handle(event)
            }
        }
    }

    /// Drops an engine that failed to load, before another is tried.
    private func discardEngine() {
        eventTask?.cancel()
        eventTask = nil
        engine?.close()
        engine = nil
        videoView = nil
        enginePaintsSubtitles = false
        isCompatibilityEngine = false
        supportsVideoAdjustments = false
        mediaInfo = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudio = nil
        selectedSubtitle = nil
        state = .loading
    }

    private func teardown() {
        saveResumePosition()
        resumeOfferTask?.cancel()
        resumeOffer = nil
        artworkTask?.cancel()
        services.sleep.setActive(false)
        services.nowPlaying.clear()
        lastResumeSave = nil
        scrubTask?.cancel()
        scrubPreview = nil
        scrubThumbnails = [:]
        scrubThumbnailsAvailable = true
        showsInfoPanel = false
        isPictureInPictureAvailable = false
        isPictureInPictureActive = false
        sidecarTask?.cancel()
        sidecarTask = nil
        subtitles.reset()
        eventTask?.cancel()
        eventTask = nil
        engine?.close()
        engine = nil
        videoView = nil
        enginePaintsSubtitles = false
        isCompatibilityEngine = false
        supportsVideoAdjustments = false
        videoAdjustments = VideoAdjustments()
        videoLayout = VideoLayout()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        folderScope?.stopAccessingSecurityScopedResource()
        folderScope = nil
        playlistTask?.cancel()
        blackBarTask?.cancel()
        blackBarRun += 1
        isDetectingBlackBars = false
        playlist = nil
        upNext = nil
        dismissedUpNext = nil
        state = .idle
        cancelHideTimer()
        controlsVisible = true
        currentTime = .zero
        duration = .zero
        buffered = .zero
        isBuffering = false
        mediaInfo = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudio = nil
        selectedSubtitle = nil
    }

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .stateChanged(let newState):
            state = newState
            // A new state counts as activity: paused shows the controls, playing starts the countdown.
            registerActivity()
            services.sleep.setActive(newState == .playing)
            if newState == .paused || newState == .ended { saveResumePosition() }
            if newState == .ended { playNextEpisodeIfDue() }
            publishNowPlaying()
        case .timeChanged(let time):
            currentTime = time
            saveResumePositionIfDue()
            updateUpNext()
        case .durationChanged(let newDuration):
            duration = newDuration
            publishNowPlaying()
        case .bufferingChanged(let buffering): isBuffering = buffering
        case .bufferedChanged(let end): buffered = end
        case .pictureInPictureChanged(let active): isPictureInPictureActive = active
        case .mediaInfoChanged(let info):
            mediaInfo = info
            publishNowPlaying()
        case .tracksChanged: refreshTracks()
        }
    }

    private func refreshTracks() {
        guard let engine else { return }
        audioTracks = engine.audioTracks
        subtitleTracks = engine.subtitleTracks
        selectedAudio = engine.selectedAudioTrack
        selectedSubtitle = engine.selectedSubtitleTrack
    }

    /// Applies the remembered audio and subtitle languages to a freshly loaded file.
    private func applyTrackPreferences(to engine: any PlaybackEngine) {
        if let audio = TrackSelectionPolicy.audio(from: engine.audioTracks, preferredLanguage: preferences.audioLanguage),
           audio != engine.selectedAudioTrack {
            engine.selectAudio(audio)
        }
        let decision = TrackSelectionPolicy.subtitle(
            from: engine.subtitleTracks,
            choice: preferences.subtitleChoice,
            audioLanguage: engine.selectedAudioTrack?.language
        )
        if case .select(let track) = decision, track != engine.selectedSubtitleTrack {
            engine.selectSubtitle(track)
        }
        refreshTracks()
    }

    // MARK: Transport

    func play() { engine?.play() }
    func pause() { engine?.pause() }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to time: Duration, precise: Bool = false) {
        let clamped = min(max(time, .zero), duration)
        currentTime = clamped
        publishNowPlaying()
        guard let engine else { return }
        Task { await engine.seek(to: clamped, precise: precise) }
    }

    func skip(by offset: Duration) {
        seek(to: currentTime + offset)
    }

    func stepFrame(forward: Bool) {
        engine?.step(frames: forward ? 1 : -1)
    }

    // MARK: Controls visibility

    private var shouldKeepControlsVisible: Bool {
        !isPlaying || isPointerOverControls || activePanel != nil || showsInfoPanel
    }

    /// Call on mouse movement or any key. Shows the controls and restarts the auto-hide countdown.
    func registerActivity() {
        lastActivity = .now
        controlsVisible = true
        startHideTimerIfNeeded()
    }

    func setPointerOverControls(_ isOver: Bool) {
        guard isOver != isPointerOverControls else { return }
        isPointerOverControls = isOver
        if isOver { cancelHideTimer() }
        registerActivity()
    }

    private func startHideTimerIfNeeded() {
        guard hideTask == nil, !shouldKeepControlsVisible else { return }
        hideTask = Task {
            // Mouse movement only moves `lastActivity`, so this loop re-sleeps instead of restarting.
            while !Task.isCancelled {
                let deadline = lastActivity + autoHideDelay
                guard ContinuousClock.now < deadline else { break }
                try? await Task.sleep(until: deadline, clock: .continuous)
            }
            guard !Task.isCancelled else { return }
            hideTask = nil
            if !shouldKeepControlsVisible { controlsVisible = false }
        }
    }

    private func cancelHideTimer() {
        hideTask?.cancel()
        hideTask = nil
    }

    // MARK: Resume, Now Playing and artwork

    /// Saves where playback is, so the file can offer to resume. Also called on quit.
    func saveResumePosition() {
        guard let url = currentURL, duration > .zero else { return }
        services.resume.update(url: url, position: currentTime.seconds, duration: duration.seconds)
        lastResumeSave = .now
    }

    private func saveResumePositionIfDue() {
        guard isPlaying else { return }
        if let last = lastResumeSave, ContinuousClock.now - last < resumeSaveInterval { return }
        saveResumePosition()
    }

    private func offerResume(for url: URL) {
        guard let record = services.resume.record(for: url), ResumeStore.isOfferable(record) else { return }
        resumeOffer = ResumeOffer(position: .seconds(record.position))
        resumeOfferTask?.cancel()
        resumeOfferTask = Task {
            try? await Task.sleep(for: resumeOfferDuration)
            guard !Task.isCancelled else { return }
            resumeOffer = nil
        }
    }

    func acceptResumeOffer() {
        guard let offer = resumeOffer else { return }
        dismissResumeOffer()
        seek(to: offer.position, precise: true)
    }

    func dismissResumeOffer() {
        resumeOfferTask?.cancel()
        resumeOffer = nil
    }

    private func publishNowPlaying() {
        guard hasMedia, duration > .zero else { return }
        services.nowPlaying.publish(NowPlayingInfo(
            title: displayTitle, duration: duration.seconds, elapsed: currentTime.seconds,
            rate: Double(rate), isPlaying: isPlaying
        ))
    }

    private func loadArtwork(from engine: any PlaybackEngine) {
        artworkTask?.cancel()
        artworkTask = Task {
            let time: Duration = duration > .zero ? min(duration / 10, .seconds(60)) : .seconds(5)
            let image = await engine.thumbnail(at: time, maxSize: CGSize(width: 640, height: 640))
            guard !Task.isCancelled else { return }
            services.nowPlaying.setArtwork(image)
            if let image, let url = currentURL { services.thumbnails.save(image, for: url) }
        }
    }

    // MARK: Info panel, scrub previews and recents

    func toggleInfoPanel() {
        showsInfoPanel.toggle()
        registerActivity()
    }

    /// Closes whatever Esc should close: an open panel first, then the info panel. Returns whether anything closed.
    @discardableResult
    func dismissTopmostOverlay() -> Bool {
        if activePanel != nil {
            closePanel()
            return true
        }
        if showsInfoPanel {
            showsInfoPanel = false
            registerActivity()
            return true
        }
        return false
    }

    /// Pointer over the scrubber at `fraction` of the way along (nil when it leaves).
    func updateScrubPreview(fraction: Double?) {
        scrubTask?.cancel()
        guard let fraction, duration > .zero, let engine else {
            scrubPreview = nil
            return
        }
        let clamped = min(max(fraction, 0), 1)
        let time = Duration.seconds(clamped * duration.seconds)
        // Thumbnails come from nearby keyframes, so a coarse grid loses nothing and keeps the cache small.
        let step = max(2, duration.seconds / 120)
        let bucket = Int((time.seconds / step).rounded())
        let cached = scrubThumbnails[bucket]
        scrubPreview = ScrubPreview(fraction: clamped, time: time, image: cached ?? scrubPreview?.image)
        guard cached == nil else { return }
        scrubTask = Task {
            let image = await engine.thumbnail(at: .seconds(Double(bucket) * step), maxSize: CGSize(width: 320, height: 180))
            guard !Task.isCancelled else { return }
            guard let image else {
                scrubThumbnailsAvailable = false
                scrubPreview?.image = nil
                return
            }
            if scrubThumbnails.count > 200 { scrubThumbnails = [:] }
            scrubThumbnails[bucket] = image
            scrubPreview?.image = image
        }
    }

    func recentPoster(for entry: RecentEntry) -> NSImage? {
        services.thumbnails.image(forPath: entry.path)
    }

    /// How far through the file the saved position is, 0...1, for the welcome screen's progress bars.
    func recentProgress(for entry: RecentEntry) -> Double? {
        guard let record = services.resume.record(for: URL(fileURLWithPath: entry.path)), record.duration > 0 else { return nil }
        return min(max(record.position / record.duration, 0), 1)
    }

    func removeRecent(_ entry: RecentEntry) {
        services.recents.remove(entry)
        services.thumbnails.remove(forPath: entry.path)
    }

    func openRecent(_ entry: RecentEntry) {
        if let url = services.recents.resolve(entry) {
            open(url)
        } else {
            removeRecent(entry)
        }
    }

    // MARK: Chapters and Picture in Picture

    func goToChapter(_ chapter: Chapter) {
        seek(to: chapter.start, precise: true)
    }

    func nextChapter() -> Chapter? {
        guard let chapter = ChapterNavigation.next(after: currentTime, in: chapters) else { return nil }
        goToChapter(chapter)
        return chapter
    }

    func previousChapter() -> Chapter? {
        guard let chapter = ChapterNavigation.previous(before: currentTime, in: chapters) else { return nil }
        goToChapter(chapter)
        return chapter
    }

    func togglePictureInPicture() {
        engine?.togglePictureInPicture()
    }

    // MARK: Crop, aspect and zoom

    func setAspect(_ aspect: VideoLayout.Aspect) { updateLayout { $0.aspect = aspect } }
    func setCrop(_ crop: VideoLayout.Crop) { updateLayout { $0.crop = crop; $0.detectedCrop = nil } }
    func setZoom(_ zoom: VideoLayout.Zoom) { updateLayout { $0.zoom = zoom } }
    func resetVideoLayout() { updateLayout { $0 = VideoLayout() } }

    private func updateLayout(_ change: (inout VideoLayout) -> Void) {
        var layout = videoLayout
        change(&layout)
        guard layout != videoLayout else { return }
        videoLayout = layout
        engine?.stretchesVideoToFrame = layout.aspect != .auto
    }

    // MARK: Panels

    func togglePanel(_ panel: PlayerPanel) {
        activePanel = activePanel == panel ? nil : panel
        registerActivity()
    }

    func closePanel() {
        guard activePanel != nil else { return }
        activePanel = nil
        registerActivity()
    }

    // MARK: Toasts

    func showToast(_ text: String, symbol: String? = nil) {
        toast = Toast(text: text, symbol: symbol)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: toastDuration)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    // MARK: Audio and rate

    func setRate(_ newRate: Float) {
        rate = min(max(newRate, 0.25), 4)
        engine?.rate = rate
        publishNowPlaying()
    }

    func setVolume(_ newVolume: Float) {
        volume = min(max(newVolume, 0), 1)
        engine?.volume = volume
    }

    func toggleMute() {
        isMuted.toggle()
        engine?.isMuted = isMuted
    }

    func setAudioOutputMode(_ mode: AudioOutputMode) {
        audioOutputMode = mode
        preferences.audioOutputMode = mode
        engine?.audioOutputMode = mode
    }

    /// Subtitle tracks the user can pick. Forced-only tracks are chosen automatically, not listed.
    var selectableSubtitleTracks: [MediaTrack] { subtitleTracks.filter { !$0.isForced } }

    /// The selected subtitle track as the user sees it: a forced-only track counts as Off.
    var displayedSubtitle: MediaTrack? { selectedSubtitle.flatMap { $0.isForced ? nil : $0 } }

    // MARK: Sidecar subtitles

    /// Whether an embedded or sidecar subtitle is showing.
    var hasVisibleSubtitle: Bool { displayedSubtitle != nil || subtitles.selected != nil }

    /// Selects a sidecar track and turns embedded subtitles off (a forced one in the audio language still shows).
    func selectExternalSubtitle(_ track: SubtitleTrackStore.Track, remember: Bool = true) {
        subtitles.select(track.id)
        if case .select(let forced) = TrackSelectionPolicy.subtitle(
            from: subtitleTracks, choice: .off, audioLanguage: selectedAudio?.language
        ) {
            engine?.selectSubtitle(forced)
        }
        refreshTracks()
        if remember, let language = track.language { preferences.subtitleChoice = .language(language) }
    }

    /// Reads a subtitle file the user picked and shows it.
    func addSubtitleFile(_ url: URL) {
        if let engine, engine.drawsSubtitlesNatively, SidecarSubtitles.nativeExtensions.contains(url.pathExtension.lowercased()) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.deletingPathExtension().lastPathComponent
            if let track = engine.addExternalSubtitle(url, title: name, language: nil) {
                selectSubtitle(track)
                showToast("Subtitles: \(name)", symbol: "captions.bubble")
            } else {
                showToast("Couldn't read that subtitle file", symbol: "exclamationmark.triangle")
            }
            return
        }
        Task {
            do {
                let track = try await subtitles.add(fileAt: url)
                selectExternalSubtitle(track)
                showToast("Subtitles: \(track.label)", symbol: "captions.bubble")
            } catch is CancellationError {
            } catch {
                showToast("Couldn't read that subtitle file", symbol: "exclamationmark.triangle")
            }
        }
    }

    /// Asks for access to the video's folder, so sidecar files next to it can load, and remembers the choice.
    func requestSidecarFolderAccess() {
        guard let url = currentURL else { return }
        OpenPanel.chooseFolder(startingAt: url.deletingLastPathComponent()) { [weak self] folder in
            guard let self else { return }
            try? folderAccess.remember(folder)
            loadSidecarSubtitles(for: url)
        }
    }

    private func loadSidecarSubtitles(for url: URL) {
        sidecarTask?.cancel()
        sidecarTask = Task {
            loadPlaylist(for: url)
            await subtitles.discover(for: url, enginePaintsSubtitles: enginePaintsSubtitles)
            guard !Task.isCancelled, currentURL == url else { return }
            addNativeSidecars(for: url)
            applySidecarPreference()
        }
    }

    /// Hands the engine the sidecar files it draws itself (ASS keeps its styling), so they join the embedded tracks.
    private func addNativeSidecars(for media: URL) {
        guard let engine, engine.drawsSubtitlesNatively, !subtitles.nativeCandidates.isEmpty else { return }
        let scopedFolder = folderAccess.beginAccess(toFolderContaining: media)
        defer { scopedFolder?.stopAccessingSecurityScopedResource() }
        for candidate in subtitles.nativeCandidates {
            _ = engine.addExternalSubtitle(candidate.url, title: candidate.label == "Subtitles" ? nil : candidate.label, language: candidate.language)
        }
        refreshTracks()
        // The remembered language may now match one of them.
        if selectedSubtitle == nil, subtitles.selected == nil,
           case .select(let track) = TrackSelectionPolicy.subtitle(from: subtitleTracks, choice: preferences.subtitleChoice, audioLanguage: selectedAudio?.language) {
            engine.selectSubtitle(track)
            refreshTracks()
        }
    }

    /// With no embedded subtitle showing, picks a sidecar track to match the remembered choice.
    private func applySidecarPreference() {
        guard subtitles.selected == nil, displayedSubtitle == nil, !subtitles.tracks.isEmpty else { return }
        let track: SubtitleTrackStore.Track?
        switch preferences.subtitleChoice {
        case .off: track = nil
        case .language(let language): track = subtitles.tracks.first { LanguageMatching.matches($0.language, language) }
        case .unset: track = selectableSubtitleTracks.isEmpty ? subtitles.tracks.first : nil
        }
        if let track { selectExternalSubtitle(track, remember: false) }
    }

    func adjustSubtitleDelayByShortcut(_ offset: Duration) {
        registerActivity()
        guard canDelaySubtitles else {
            showToast("Delay needs a subtitle file", symbol: "captions.bubble")
            return
        }
        subtitles.adjustDelay(by: offset)
        engine?.setSubtitleDelay(subtitles.delay)
        showToast("Subtitle delay \(subtitles.delayLabel)", symbol: "captions.bubble")
    }

    func resetSubtitleDelay() {
        subtitles.resetDelay()
        engine?.setSubtitleDelay(subtitles.delay)
        showToast("Subtitle delay \(subtitles.delayLabel)", symbol: "captions.bubble")
    }

    /// The playhead for subtitle timing. Reads the engine directly because `currentTime` only updates 4 times a second.
    func livePlaybackTime() -> Duration {
        engine?.currentTime ?? currentTime
    }

    func activeSubtitleCues() -> [SubtitleCue] {
        let time = isPlaying ? livePlaybackTime() : currentTime
        if subtitles.selected != nil { return subtitles.activeCues(atPlaybackTime: time) }
        return engineDrawnCues?.active(at: time - subtitles.delay) ?? []
    }

    /// The cues of the selected embedded track when the engine hands them over to be drawn by the app (MKV text subtitles),
    /// else nil: AVFoundation draws its own tracks.
    private var engineDrawnCues: SubtitleCueList? {
        selectedSubtitle.flatMap { engine?.subtitleCues(for: $0) }
    }

    /// Whether the app draws a subtitle over the video, so the overlay applies.
    var drawsSubtitles: Bool { subtitles.selected != nil || engineDrawnCues != nil }

    /// Whether a subtitle is showing that the delay controls can shift: one the app draws, or one the engine does.
    var canDelaySubtitles: Bool { drawsSubtitles || (enginePaintsSubtitles && displayedSubtitle != nil) }

    func setSubtitleStyle(_ style: SubtitleStyle) {
        subtitles.setStyle(style)
        engine?.setSubtitleStyle(style)
    }

    /// How far above the bottom of the visible picture subtitles sit, as a fraction of its height: the app's own position, lifted
    /// clear of the control bar while it shows. The same number places an engine's own subtitles (`setSubtitleLift`).
    func nativeSubtitleLift(container: CGSize) -> Double {
        let rect = VideoGeometry.placement(container: container, videoSize: mediaInfo?.presentationSize, layout: videoLayout).clipRect
        guard rect.height > 0 else { return 0.06 + subtitles.style.verticalOffset }
        let bottom = SubtitleLayout.bottomInset(videoRect: rect, container: container, style: subtitles.style, controlsVisible: controlsVisible)
        return Double(bottom / rect.height)
    }

    func setSubtitleLift(_ fraction: Double) {
        engine?.setSubtitleLift(fraction)
    }

    /// Switches audio track mid-playback and remembers its language for the next file.
    func selectAudio(_ track: MediaTrack?) {
        engine?.selectAudio(track)
        refreshTracks()
        if let language = track?.language { preferences.audioLanguage = language }
    }

    /// `nil` turns subtitles off (a forced track in the audio language still shows). The choice is remembered.
    func selectSubtitle(_ track: MediaTrack?) {
        subtitles.select(nil)
        if let track {
            engine?.selectSubtitle(track)
            if let language = track.language { preferences.subtitleChoice = .language(language) }
        } else {
            let forced = TrackSelectionPolicy.subtitle(
                from: subtitleTracks, choice: .off, audioLanguage: selectedAudio?.language
            )
            if case .select(let forcedTrack) = forced { engine?.selectSubtitle(forcedTrack) }
            preferences.subtitleChoice = .off
        }
        refreshTracks()
    }
}

/// The card that offers the next episode near the end of this one.
struct UpNext: Equatable {
    var url: URL
    /// `S02E06`, when the name has one.
    var label: String?
    var name: String
    /// Whether it starts on its own when this episode ends.
    var startsAutomatically: Bool
}

/// The thumbnail and time shown above the scrubber while the pointer is on it.
struct ScrubPreview {
    var fraction: Double
    var time: Duration
    var image: CGImage?
}

enum PlayerPanel: Equatable {
    case audioSubtitles
    case crop
    case adjustments
    case speed
}

// MARK: Folder playlist and "Up next"

/// Next and previous file in the folder, and "Up next" for episodes (PLAN.md phase 4).
extension PlayerModel {
    var hasNextFile: Bool { playlist?.next != nil }
    var hasPreviousFile: Bool { playlist?.previous != nil }

    func setAutoplaysNextEpisode(_ enabled: Bool) {
        autoplaysNextEpisode = enabled
        preferences.autoplaysNextEpisode = enabled
        updateUpNext()
    }

    /// Lists the open file's folder. Without folder access (the sandbox only lets the app see the file itself) there is no playlist,
    /// and the track panel offers to grant it.
    func loadPlaylist(for url: URL) {
        playlistTask?.cancel()
        if folderScope == nil { folderScope = folderAccess.beginAccess(toFolderContaining: url) }
        playlistTask = Task {
            let siblings = await Task.detached(priority: .userInitiated) {
                try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            }.value
            guard !Task.isCancelled, currentURL == url else { return }
            playlist = siblings.flatMap { FolderPlaylist(current: url, siblings: $0) }
            updateUpNext()
        }
    }

    func playNextFile() {
        registerActivity()
        guard let next = playlist?.next else {
            showToast("This is the last video in the folder", symbol: "forward.end")
            return
        }
        open(next)
    }

    func playPreviousFile() {
        registerActivity()
        guard let previous = playlist?.previous else {
            showToast("This is the first video in the folder", symbol: "backward.end")
            return
        }
        open(previous)
    }

    /// The "Play Now" button on the card.
    func playUpNext() {
        guard let upNext else { return }
        open(upNext.url)
    }

    /// The card's close button: this episode will not hand over to the next one by itself.
    func dismissUpNext() {
        dismissedUpNext = currentURL
        upNext = nil
    }

    func updateUpNext() {
        let candidate = upNextCandidate()
        if candidate != upNext { upNext = candidate }
    }

    private func upNextCandidate() -> UpNext? {
        guard let next = playlist?.nextEpisode, let current = currentURL, dismissedUpNext != current,
              duration > .seconds(60), duration - currentTime <= upNextLeadTime, state == .playing || state == .paused
        else { return nil }
        let name = next.deletingPathExtension().lastPathComponent
        return UpNext(
            url: next, label: EpisodeNumber.parse(fileName: next.lastPathComponent)?.label, name: name,
            startsAutomatically: autoplaysNextEpisode
        )
    }

    /// At the end of an episode the next one follows, unless the user turned that off or closed the card.
    func playNextEpisodeIfDue() {
        guard autoplaysNextEpisode, dismissedUpNext != currentURL, let next = playlist?.nextEpisode else { return }
        open(next)
    }
}

// MARK: Black bars

extension PlayerModel {
    func setCropsBlackBarsAutomatically(_ enabled: Bool) {
        cropsBlackBarsAutomatically = enabled
        preferences.cropsBlackBarsAutomatically = enabled
    }

    /// Looks at stills from across the file for black bars baked into the picture and crops them off. `announce` is true for the
    /// user's own request, which always answers with a toast; the automatic run at open only speaks when it crops.
    func detectBlackBars(announce: Bool = true) {
        guard let engine, duration > .zero, !isDetectingBlackBars else { return }
        blackBarTask?.cancel()
        blackBarRun += 1
        let run = blackBarRun
        isDetectingBlackBars = true
        if announce { showToast("Looking for black bars…", symbol: "crop") }
        let length = duration
        let size = mediaInfo?.presentationSize ?? .zero
        blackBarTask = Task {
            // A run overtaken by a newer one (after the file changed) must not clear the newer run's flag.
            defer { if run == blackBarRun { isDetectingBlackBars = false } }
            var stills: [BlackBarDetector.Bars?] = []
            for step in 1...10 {
                guard !Task.isCancelled else { return }
                let at = Duration.seconds(length.seconds * (0.05 + 0.09 * Double(step - 1)))
                let image = await engine.thumbnail(at: at, maxSize: CGSize(width: 400, height: 400))
                stills.append(image.flatMap { BlackBarDetector.bars(in: $0) })
            }
            guard !Task.isCancelled else { return }
            guard let bars = BlackBarDetector.commonBars(stills), let ratio = BlackBarDetector.cropRatio(bars: bars, displaySize: size) else {
                if announce { showToast("No black bars found", symbol: "crop") }
                return
            }
            updateLayout { $0.detectedCrop = ratio; $0.crop = .none }
            showToast("Cropped black bars: \(VideoLayout.label(forRatio: ratio))", symbol: "crop")
        }
    }
}

// MARK: Picture adjustments

extension PlayerModel {
    func setVideoAdjustments(_ adjustments: VideoAdjustments) {
        let value = adjustments.clamped()
        guard value != videoAdjustments else { return }
        videoAdjustments = value
        engine?.setVideoAdjustments(value)
    }

    func resetVideoAdjustments() { setVideoAdjustments(VideoAdjustments()) }

    /// Opens the picture panel, or says what it needs when the engine can't adjust.
    func showAdjustmentsPanel() {
        guard supportsVideoAdjustments else {
            showToast("Picture adjustments need the Compatibility Engine", symbol: "slider.horizontal.3")
            return
        }
        togglePanel(.adjustments)
    }
}

// MARK: Screenshots

extension PlayerModel {
    /// Saves the frame on screen to Pictures ▸ Nit Picker, as HDR HEIC when the source is HDR and as PNG otherwise.
    func takeScreenshot() {
        registerActivity()
        guard let engine, hasMedia else { return }
        let title = displayTitle
        let time = currentTime
        Task {
            guard let frame = await engine.captureFrame(), let output = ScreenshotEncoder.encode(frame) else {
                showToast("Couldn't take a screenshot", symbol: "exclamationmark.triangle")
                return
            }
            do {
                let url = try services.screenshots.save(output, title: title, at: time)
                lastScreenshot = url
                showToast(output.isHDR ? "HDR screenshot saved to Pictures" : "Screenshot saved to Pictures", symbol: "camera")
            } catch {
                showToast("Couldn't save the screenshot", symbol: "exclamationmark.triangle")
            }
        }
    }
}

import SwiftUI

struct PlayerWindowView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowController = WindowController()
    @FocusState private var isFocused: Bool
    @State private var isDropTargeted = false
    @State private var containerSize = CGSize.zero

    private var showsControls: Bool { player.hasMedia && player.errorMessage == nil }

    var body: some View {
        ZStack {
            Color.black
            // A file that failed mid-playback keeps its video view; don't leave a frozen frame behind the message.
            if let videoView = player.videoView, player.errorMessage == nil {
                VideoSurfaceView(
                    videoView: videoView,
                    videoSize: player.mediaInfo?.presentationSize,
                    layout: player.videoLayout
                ) { windowController.toggleFullScreen() }
            }
            if player.drawsSubtitles {
                SubtitleOverlay()
            }
            if !showsControls {
                WelcomeView(isDropTargeted: isDropTargeted)
            }
            if showsControls {
                if player.activePanel != nil {
                    // Click anywhere outside the panel to dismiss it.
                    Color.clear.contentShape(Rectangle()).onTapGesture { player.closePanel() }
                }
                controls
            }
            if let upNext = player.upNext, showsControls {
                UpNextView(upNext: upNext)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 24)
                    .padding(.bottom, player.controlsVisible ? 110 : 28)
                    .transition(.opacity)
            }
            if player.isBusy {
                BusyIndicator()
            }
            toast
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self, of: \.size) { containerSize = $0 }
        // An engine that draws subtitles itself (mpv) lifts them clear of the controls. Not a view of its own: a SwiftUI layer
        // over the mpv view hides the picture.
        .onChange(of: player.nativeSubtitleLift(container: containerSize), initial: true) { _, lift in player.setSubtitleLift(lift) }
        .background(WindowAccessor { windowController.configure($0) })
        .onChange(of: player.displayTitle) { _, title in windowController.setTitle(player.hasMedia ? title : "Nit Picker") }
        .onChange(of: player.mediaInfo?.presentationSize) { _, size in
            if let size { windowController.fit(toVideoSize: size) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        // Esc closes an open panel first, and otherwise leaves full screen as usual.
        .onExitCommand {
            if !player.dismissTopmostOverlay() { windowController.exitFullScreen() }
        }
        .onContinuousHover { phase in
            if case .active = phase { player.registerActivity() }
        }
        .onChange(of: player.controlsVisible) { _, visible in
            windowController.setChromeVisible(visible)
            if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, PlayerModel.canOpen(url) else { return false }
            player.open(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    /// The bottom gradient keeps the glass readable over bright HDR highlights. It only exists
    /// while the controls are showing.
    private var controls: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            ControlsOverlay { windowController.toggleFullScreen() }
                .frame(maxHeight: .infinity, alignment: .bottom)
            InfoHUD()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 24)
                .padding(.trailing, 20)
        }
        .opacity(player.controlsVisible ? 1 : 0)
        .allowsHitTesting(player.controlsVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: player.controlsVisible)
    }

    private var toast: some View {
        VStack(spacing: 10) {
            if let toast = player.toast {
                OSDToastView(toast: toast)
                    .id(toast.id)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            if let offer = player.resumeOffer {
                ResumeOfferView(offer: offer)
                    .transition(.opacity)
            }
            Spacer()
        }
        .padding(.top, 28)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: player.toast)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: player.resumeOffer)
    }

    // The next-episode card appears and disappears without moving, so it never animates over the mpv view.
}

/// The control bar and the panel that grows out of it, in one glass container so they morph.
private struct ControlsOverlay: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace
    var onToggleFullScreen: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 24) {
            VStack(spacing: 12) {
                if let panel = player.activePanel {
                    Group {
                        switch panel {
                        case .audioSubtitles: TrackPanel()
                        case .crop: CropPanel()
                        case .adjustments: AdjustmentsPanel()
                        case .speed: SpeedPanel()
                        }
                    }
                    .glassEffectID("panel", in: glassNamespace)
                    .glassEffectTransition(.matchedGeometry)
                }
                ControlBar(namespace: glassNamespace, onToggleFullScreen: onToggleFullScreen)
            }
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .onHover { player.setPointerOverControls($0) }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: player.activePanel)
    }
}

/// A spinner for loading and buffering. It waits a moment first, so quick loads don't flash it.
private struct BusyIndicator: View {
    @State private var isShown = false

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(.white)
            .padding(22)
            .glassEffect(.regular.tint(.black.opacity(0.35)), in: .circle)
            .opacity(isShown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(400))
                isShown = true
            }
            .accessibilityLabel("Loading")
            .allowsHitTesting(false)
    }
}

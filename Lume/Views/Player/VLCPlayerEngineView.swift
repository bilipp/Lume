import SwiftData
import SwiftUI
import VLCKitSPM

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// VLCKit 4-backed video host with custom Apple-style controls.
///
/// VLCKit 4 unifies iOS / tvOS / macOS / visionOS into a single framework
/// (no more MobileVLCKit / TVVLCKit split) and adds native Picture in
/// Picture, hardware-accelerated 4K HDR and the broadest codec / IPTV
/// compatibility of the three engines.
///
/// Rendering goes through a `VLCDrawable` host (a plain platform view that
/// VLC inserts its output surface into). The same object also conforms to
/// the PiP protocols so VLC can drive an `AVPictureInPictureController`
/// internally — see `VLCPlayerCoordinator`.
struct VLCPlayerEngineView: View {
    let media: PlayableMedia
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval
    /// Invoked when the viewer picks a different stream (e.g. another episode)
    /// from the in-player overlay. The host swaps `media` in response.
    var onSelectMedia: ((PlayableMedia) -> Void)?

    @StateObject private var coordinator = VLCPlayerCoordinator()
    @State private var isControlsVisible = true
    @State private var isSeeking = false
    @State private var seekPosition: TimeInterval = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var hoverHideTask: Task<Void, Never>?
    /// While an overlay panel (episodes / info) is open the controls must not
    /// auto-hide out from under the viewer.
    @State private var isPanelOpen = false
    /// Bumped to ask the overlay to close its open panel (Menu/back press).
    @State private var panelCloseToken = 0
    /// Deinterlace preference, handed to the coordinator as a libvlc option.
    /// Defaults off on iOS/tvOS so interlaced streams keep hardware decode.
    @AppStorage(PlayerSettings.deinterlaceKey) private var deinterlace = PlayerSettings.deinterlaceDefault
    #if os(tvOS)
        /// Drives focus onto the transparent tap-catcher once the controls
        /// auto-hide, so the Siri remote can summon them again. Without this the
        /// focus engine drops focus when the overlay disappears and no further
        /// remote input reaches the catcher.
        @FocusState private var catcherFocused: Bool
        /// Live-content sort the channel browser uses — read so in-player channel
        /// surfing follows the same order the viewer saw in the list.
        @AppStorage(SortStorageKey.liveContent)
        private var liveContentSortRaw: String = ContentSortOption.playlist.rawValue
        @Environment(\.modelContext) private var modelContext
    #endif

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
        @Environment(\.dismissWindow) private var dismissWindow
    #endif

    private let autoHideInterval: TimeInterval = 4

    var body: some View {
        ZStack {
            // Backdrop. On macOS the host NSView is deliberately not
            // layer-backed (see VLCVideoContainer), so it can't paint its
            // own black fill — SwiftUI provides it here instead.
            Color.black
                .ignoresSafeArea()

            VLCVideoContainer(coordinator: coordinator)
                .ignoresSafeArea()

            // Always-present transparent layer that reliably catches taps
            // over the VLC render surface. A UIView/NSView representable can
            // otherwise swallow touches before SwiftUI's gesture sees them,
            // leaving no way to summon the controls once they auto-hide.
            tapCatcher

            if isControlsVisible {
                controlsOverlay
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            coordinator.onTime = { current in
                if !isSeeking, current.isFinite { currentTime = current }
            }
            coordinator.onDuration = { total in
                if total.isFinite, total > 0 { duration = total }
            }
            coordinator.configure(media: media, deinterlace: deinterlace)
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            hoverHideTask?.cancel()
            coordinator.tearDown()
        }
        .onChange(of: coordinator.isPlaying) { _, _ in
            resetHideTimer()
        }
        .onChange(of: scenePhase) { _, phase in
            // The Home button backgrounds the app without calling onDisappear,
            // so pause here to stop audio when the player loses focus.
            if phase != .active { coordinator.pauseForBackground() }
        }
        .onChange(of: media) { _, newMedia in
            // The host swapped the stream (e.g. a new episode). Reset local
            // scrubbing state and hand the new media to the live player.
            isSeeking = false
            seekPosition = 0
            isPanelOpen = false
            coordinator.reload(media: newMedia, deinterlace: deinterlace)
            resetHideTimer()
        }
        .onChange(of: isControlsVisible) { _, visible in
            #if os(tvOS)
                // Hand focus to the tap-catcher once the controls vanish so the
                // remote can bring them back.
                if !visible { Task { @MainActor in catcherFocused = true } }
            #endif
        }
        // Handle the Menu/back button at the player root — the always-present
        // ancestor of both the tap-catcher and the controls overlay — so it
        // reliably overrides the fullScreenCover's default dismiss-on-Menu.
        .onMenuPress { handleMenuPress() }
        // The Siri Remote's dedicated Play/Pause button is a distinct press
        // type from a click-pad Select, so the on-screen button never sees it.
        // Drive togglePlay() explicitly, otherwise the press is swallowed and
        // playback never toggles.
        .onPlayPausePress { togglePlay() }
        #if os(macOS)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active:
                    if !isControlsVisible {
                        withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = true }
                    }
                    resetHideTimer()
                    hoverHideTask?.cancel()
                case .ended:
                    hoverHideTask?.cancel()
                    hoverHideTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = false }
                    }
                }
            }
            .onKeyPress(.leftArrow) { coordinator.skip(by: -15); resetHideTimer(); return .handled }
            .onKeyPress(.rightArrow) { coordinator.skip(by: 15); resetHideTimer(); return .handled }
            .onKeyPress(.space) { togglePlay(); return .handled }
            .onKeyPress(.escape) { closePlayer(); return .handled }
        #endif
    }

    // MARK: - Tap Catcher

    @ViewBuilder
    private var tapCatcher: some View {
        #if os(tvOS)
            // tvOS has no touch surface: drive the overlay from the Siri
            // remote. The catcher only takes focus while controls are
            // hidden, so the control buttons stay reachable otherwise.
            // A focusable Button reliably catches the Siri remote's Select
            // (center) press; `onMoveCommand` covers swipes/clicks. Disabled
            // while the controls are up so the overlay's buttons own focus.
            Button(action: showControls) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(InvisibleButtonStyle())
            .disabled(isControlsVisible)
            .focused($catcherFocused)
            .onMoveCommand { direction in
                // While watching live TV with the controls hidden, up/down surf
                // adjacent channels — the classic channel rocker — and right
                // recalls the last channel watched. Any other move just summons
                // the controls.
                if media.isLive, direction == .up || direction == .down || direction == .right {
                    switchLiveChannel(direction)
                } else {
                    showControls()
                }
            }
        #else
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
        #endif
    }

    // MARK: - Controls Overlay

    @ViewBuilder
    private var controlsOverlay: some View {
        #if os(tvOS)
            TVPlayerControlsOverlay(
                coordinator: coordinator,
                media: media,
                currentTime: $currentTime,
                duration: $duration,
                panelCloseToken: panelCloseToken,
                onTogglePlay: { togglePlay() },
                onResetHideTimer: { resetHideTimer() },
                onSelectMedia: { onSelectMedia?($0) },
                onPanelOpenChange: { setPanelOpen($0) },
                onSwitchChannel: { switchLiveChannel($0) }
            )
        #else
            VLCPlayerControlsOverlay(
                coordinator: coordinator,
                media: media,
                isSeeking: $isSeeking,
                seekPosition: $seekPosition,
                currentTime: $currentTime,
                duration: $duration,
                hideTask: $hideTask,
                onClose: { closePlayer() },
                onTogglePlay: { togglePlay() },
                onResetHideTimer: { resetHideTimer() },
                onScheduleHide: { scheduleHide() }
            )
        #endif
    }

    // MARK: - Actions

    private func togglePlay() {
        coordinator.togglePlay()
        resetHideTimer()
    }

    #if os(tvOS)
        /// Change the live channel from the Siri Remote. Up/Down surf to the
        /// adjacent channel (a TV remote's channel rocker); Right recalls the
        /// channel watched just before this one (the remote's "last" button).
        /// The new channel's controls are surfaced briefly so its name and EPG
        /// act as a banner. Falls back to summoning the controls when there's
        /// nothing to jump to.
        private func switchLiveChannel(_ direction: MoveCommandDirection) {
            guard media.isLive else { return }
            let target: PlayableMedia?
            switch direction {
            case .up, .down:
                let sort = ContentSortOption(rawValue: liveContentSortRaw) ?? .playlist
                target = LiveChannelNavigator.adjacentMedia(
                    for: media, offset: direction == .up ? 1 : -1, sort: sort, in: modelContext
                )
            case .right:
                target = LiveChannelHistory.recallMedia(in: modelContext)
            default:
                return
            }
            guard let target else { showControls(); return }
            onSelectMedia?(target)
            showControls()
        }
    #endif

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible.toggle() }
        if isControlsVisible { scheduleHide() }
    }

    private func showControls() {
        guard !isControlsVisible else { resetHideTimer(); return }
        withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = true }
        scheduleHide()
    }

    /// Dismiss the controls overlay (Menu button when no panel is open). A
    /// second Menu press, with the controls hidden, dismisses the player.
    private func hideControls() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = false }
    }

    /// Menu/back routing: close an open panel first, then hide the controls,
    /// and only dismiss the player once the controls are already hidden.
    private func handleMenuPress() {
        if isPanelOpen {
            panelCloseToken += 1
        } else if isControlsVisible {
            hideControls()
        } else {
            closePlayer()
        }
    }

    private func resetHideTimer() {
        hideTask?.cancel()
        if isControlsVisible { scheduleHide() }
    }

    /// Keep the controls pinned open while an overlay panel is showing.
    private func setPanelOpen(_ open: Bool) {
        isPanelOpen = open
        if open {
            hideTask?.cancel()
        } else {
            resetHideTimer()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard coordinator.isPlaying, !isPanelOpen else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(autoHideInterval * 1_000_000_000))
            guard !Task.isCancelled, coordinator.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = false }
        }
    }

    private func closePlayer() {
        #if os(macOS)
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            dismissWindow(id: "player")
        #else
            dismiss()
        #endif
    }
}

#if os(tvOS)
    /// Draws only its (clear) label — no focus highlight, scale or background —
    /// so the full-screen tap-catcher stays invisible even while it holds focus
    /// with the controls hidden.
    private struct InvisibleButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
        }
    }
#endif

private extension View {
    /// Runs `action` on the Siri remote's Menu/back press (tvOS only); a no-op
    /// elsewhere so the cross-platform body still compiles.
    @ViewBuilder
    func onMenuPress(perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
            onExitCommand(perform: action)
        #else
            self
        #endif
    }

    /// Runs `action` on the Siri remote's dedicated Play/Pause button (tvOS
    /// only); a no-op elsewhere so the cross-platform body still compiles.
    @ViewBuilder
    func onPlayPausePress(perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
            onPlayPauseCommand(perform: action)
        #else
            self
        #endif
    }
}

    // MARK: - Video Container (platform view bridge)

// Hosts the plain platform view that VLC renders into. The coordinator is
// set as the player's `drawable`; VLC calls back into it to insert its
// output surface and to query bounds.
#if os(macOS)
    private struct VLCVideoContainer: NSViewRepresentable {
        let coordinator: VLCPlayerCoordinator

        func makeNSView(context _: Context) -> NSView {
            // Deliberately NOT layer-backed: VLCKit's macOS video output
            // inserts a legacy `NSOpenGLView`. Inside a layer-backed view
            // tree, on Apple Silicon's deprecated OpenGL-on-Metal shim,
            // VLC's renderer aborts with `GL_INVALID_OPERATION` in
            // `CreateFilters` (vout_helper.c). Leaving `wantsLayer` unset
            // lets the GL view present the traditional, non-layer-backed
            // way. SwiftUI may still force layer-backing from an ancestor;
            // if so this won't be enough and macOS playback should fall
            // back to a Metal-based engine (KSPlayer).
            let view = NSView()
            coordinator.attach(hostView: view)
            return view
        }

        func updateNSView(_: NSView, context _: Context) {}
    }
#else
    private struct VLCVideoContainer: UIViewRepresentable {
        let coordinator: VLCPlayerCoordinator

        func makeUIView(context _: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .black
            coordinator.attach(hostView: view)
            return view
        }

        func updateUIView(_: UIView, context _: Context) {}
    }
#endif

#Preview("Fallback") {
    VLCPlayerEngineView(
        media: PlayableMedia(
            id: "preview",
            url: URL(string: "https://example.com/stream.m3u8")!,
            title: "Sample Video",
            subtitle: nil,
            posterURL: nil,
            kind: .vod,
            startTime: 0,
            contentRef: .movie("preview")
        ),
        currentTime: .constant(0),
        duration: .constant(120)
    )
    .preferredColorScheme(.dark)
}

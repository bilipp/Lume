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
    /// High-frequency playback clock, held as the `@Observable` object rather
    /// than as `@Binding` scalars. A `@Binding` whose root is an `@Observable`
    /// makes the *holding* view re-render on every change — so binding the clock
    /// here re-rendered the engine view (and rebuilt the controls overlay /
    /// menus) on every playback tick. Holding the object and never reading
    /// `current`/`duration` in this body keeps the engine view off the tick path;
    /// only the scrubber leaf reads it. `@Bindable` so the iOS/macOS overlay can
    /// still take plain bindings.
    @Bindable var clock: PlaybackClock
    /// The episode queued after `media`, resolved by the host. Drives the
    /// end-of-episode Next Up affordances; `nil` when there is nothing to play
    /// next.
    var nextUpMedia: PlayableMedia?
    /// Intro / recap windows for the active episode (from IntroDB), driving the
    /// in-player Skip Intro button. `nil` when there is nothing to skip.
    var skipSegments: IntroSegments?
    /// Whether the host has another engine to fall back to if this one can't
    /// start the stream. When true, an initial-load failure reports to the host
    /// (which switches engines) instead of raising the error overlay, and the
    /// startup watchdog uses the shorter fallback timeout so the switch is prompt.
    var fallbackAvailable = false
    /// Invoked when this engine can't start the stream and a fallback engine is
    /// available. The host advances to the next engine in the priority list.
    var onPlaybackFailed: (() -> Void)?
    /// Invoked when the viewer picks a different stream (e.g. another episode)
    /// from the in-player overlay. The host swaps `media` in response.
    var onSelectMedia: ((PlayableMedia) -> Void)?

    @StateObject private var coordinator = VLCPlayerCoordinator()
    @State private var isControlsVisible = true
    /// Set once the stream is given up on (initial-load failure with no fallback
    /// left). Swaps the player for the `PlayerErrorIndicator` (Try Again / Back).
    @State private var loadFailed = false
    @State private var isSeeking = false
    @State private var seekPosition: TimeInterval = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var hoverHideTask: Task<Void, Never>?
    /// While an overlay panel (episodes / info) is open the controls must not
    /// auto-hide out from under the viewer.
    @State private var isPanelOpen = false
    /// Bumped to ask the overlay to close its open panel (Menu/back press).
    @State private var panelCloseToken = 0
    #if os(tvOS)
        /// The full channel browser (categories + channels) raised by a left
        /// press while watching live TV with the controls hidden.
        @State private var isChannelBrowserOpen = false
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
    /// How long to wait for the first frame before declaring a stream dead when
    /// this is the last engine in the priority list.
    private let startupTimeout: TimeInterval = 40
    /// Shorter startup timeout used when a fallback engine is available, so a
    /// hanging engine hands off promptly rather than stalling on a black screen.
    private let fallbackStartupTimeout: TimeInterval = 15

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

            if isControlsVisible, !loadFailed {
                controlsOverlay
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            if let nextUpMedia {
                PlayerNextUpOverlay(
                    nextMedia: nextUpMedia,
                    clock: clock,
                    controlsVisible: isControlsVisible,
                    onPlayNext: { onSelectMedia?($0) }
                )
            }

            if let skipSegments {
                PlayerSkipIntroOverlay(
                    segments: skipSegments,
                    clock: clock,
                    controlsVisible: isControlsVisible,
                    onSeek: { time in
                        coordinator.seek(to: time)
                        #if os(tvOS)
                            // The skip button held focus; hand it back to the
                            // tap-catcher so the remote keeps working.
                            Task { @MainActor in catcherFocused = true }
                        #endif
                    }
                )
            }

            #if os(tvOS)
                if isChannelBrowserOpen {
                    channelBrowser
                }
            #endif

            if loadFailed {
                PlayerErrorIndicator(
                    title: media.title,
                    onRetry: { retryPlayback() },
                    onClose: { closePlayer() }
                )
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            coordinator.onTime = { current in
                if !isSeeking, current.isFinite { clock.current = current }
            }
            coordinator.onDuration = { total in
                if total.isFinite, total > 0 { clock.duration = total }
            }
            coordinator.onPlaybackFailure = { reportFailure() }
            coordinator.startupTimeout = fallbackAvailable ? fallbackStartupTimeout : startupTimeout
            coordinator.configure(media: media)
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
            loadFailed = false
            coordinator.reload(media: newMedia)
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
            // Yield focus to the failure overlay's buttons when a stream dies.
            .disabled(isControlsVisible || isChannelBrowserOpen || loadFailed)
            .focused($catcherFocused)
            .onMoveCommand { direction in
                // While watching live TV with the controls hidden, left opens
                // the channel browser, up/down surf adjacent channels — the
                // classic channel rocker — and right recalls the last channel
                // watched. Any other move just summons the controls.
                if media.isLive, direction == .left {
                    openChannelBrowser()
                } else if media.isLive, direction == .up || direction == .down || direction == .right {
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
                clock: clock,
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
                currentTime: $clock.current,
                duration: $clock.duration,
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

        /// The two-column category / channel browser, slid in over the leading
        /// edge. Picking a channel switches the stream and surfaces the controls
        /// briefly so the new channel's name and EPG act as a banner.
        private var channelBrowser: some View {
            TVChannelBrowserOverlay(
                media: media,
                onSelect: { target in
                    onSelectMedia?(target)
                    withAnimation(.easeInOut(duration: 0.25)) { isChannelBrowserOpen = false }
                    showControls()
                },
                onClose: { closeChannelBrowser() }
            )
            .transition(.move(edge: .leading).combined(with: .opacity))
        }

        private func openChannelBrowser() {
            guard media.isLive, !isChannelBrowserOpen else { return }
            hideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.25)) { isChannelBrowserOpen = true }
        }

        private func closeChannelBrowser() {
            withAnimation(.easeInOut(duration: 0.25)) { isChannelBrowserOpen = false }
            // Hand focus back to the tap-catcher so the remote keeps working.
            Task { @MainActor in catcherFocused = true }
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

    /// Menu/back routing: close the channel browser or an open panel first,
    /// then hide the controls, and only dismiss the player once the controls
    /// are already hidden.
    private func handleMenuPress() {
        if loadFailed {
            closePlayer()
            return
        }
        #if os(tvOS)
            if isChannelBrowserOpen {
                closeChannelBrowser()
                return
            }
        #endif
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

    /// The coordinator reported it can't start the stream. On an initial-load
    /// failure with a fallback engine available, hand off to the host (which
    /// switches engines); otherwise raise the failure overlay.
    private func reportFailure() {
        guard !loadFailed else { return }
        if fallbackAvailable, !coordinator.hasStartedPlayback {
            onPlaybackFailed?()
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) { loadFailed = true }
    }

    /// Re-prepare the current stream after a failure (the Try Again button).
    private func retryPlayback() {
        withAnimation(.easeInOut(duration: 0.25)) { loadFailed = false }
        coordinator.retryAfterFailure()
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
        clock: PlaybackClock()
    )
    .preferredColorScheme(.dark)
}

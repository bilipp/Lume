import LumeEngine
import OSLog
import SwiftData
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// LumeEngine (FFmpeg) video host with the shared Apple-style player controls.
///
/// On tvOS it hosts the shared `TVPlayerControlsOverlay` — the very same
/// Apple-TV-style overlay the VLCKit and KSPlayer engines use — via the
/// `TVPlaybackEngine` conformance on `LumeEngineCoordinator`, so every engine
/// presents an identical player UI. On iOS / macOS it layers the matching
/// `LumeEngineControlsOverlay`. The engine renders its own subtitle cues, drawn
/// here above the video surface.
struct LumeEngineEngineView: View {
    let media: PlayableMedia
    /// High-frequency playback clock, held as the `@Observable` object rather
    /// than as `@Binding` scalars. A `@Binding` whose root is an `@Observable`
    /// makes the *holding* view re-render on every change — so binding the clock
    /// here would rebuild the controls overlay / menus on every playback tick.
    /// Holding the object and never reading `current`/`duration` in this body
    /// keeps the engine view off the tick path; only the scrubber leaf reads it.
    @Bindable var clock: PlaybackClock
    /// The episode queued after `media`, resolved by the host. Drives the
    /// end-of-episode Next Up affordances; `nil` when there is nothing to play
    /// next.
    var nextUpMedia: PlayableMedia?
    /// Intro / recap windows for the active episode (from IntroDB), driving the
    /// in-player Skip Intro button. `nil` when there is nothing to skip.
    var skipSegments: IntroSegments?
    /// When true, an initial-load failure reports to the host via
    /// `onPlaybackFailed` (which decides what to try next) instead of raising
    /// this engine's own error overlay.
    var reportsStartupFailure = false
    /// Use the shorter fallback startup window before declaring failure, so a
    /// switch to the next engine is prompt. Off for attempts that should wait
    /// out the full startup timeout.
    var usesQuickStartupTimeout = false
    /// Invoked on an initial-load failure when `reportsStartupFailure` is set.
    var onPlaybackFailed: (() -> Void)?
    /// Invoked when the viewer picks a different stream (another episode, or a
    /// live channel via the Siri remote) from the in-player overlay. The host
    /// swaps `media` in response.
    var onSelectMedia: ((PlayableMedia) -> Void)?

    @StateObject private var coordinator = LumeEngineCoordinator()
    /// Drives bounded backoff reconnects when the stream drops mid-playback.
    @State private var reconnector = PlaybackRetryController()
    @State private var isControlsVisible = true
    /// Set once the stream is given up on (initial-load failure with no fallback
    /// left, or the reconnect budget spent). Swaps the player for the
    /// `PlayerErrorIndicator` (Try Again / Back).
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
        /// auto-hide, so the Siri remote can summon them again.
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
            Color.black
                .ignoresSafeArea()

            LumeEngineVideoSurface(coordinator: coordinator)
                .ignoresSafeArea()

            // The engine decodes the selected subtitle into `subtitleCues`; the
            // bare video surface draws only video, so this leaf renders those
            // cues. It observes the standalone cue model (not the coordinator),
            // so per-cue updates invalidate this leaf alone — never this body
            // (which would rebuild the controls overlay / open track menus).
            LumeEngineSubtitleOverlay(cues: coordinator.subtitleCues, controlsVisible: isControlsVisible)

            // Always-present transparent layer that reliably catches taps over
            // the engine's render layer, which can otherwise swallow touches
            // before SwiftUI's gesture sees them.
            tapCatcher
                .ignoresSafeArea()

            // Hold the controls back until the stream starts, so the loading
            // indicator stands in for a player that would otherwise look paused
            // behind its Play button.
            if isControlsVisible, coordinator.hasStartedPlayback, !loadFailed {
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

            if coordinator.isBuffering, !loadFailed {
                PlayerLoadingIndicator(title: coordinator.hasStartedPlayback ? nil : media.title)
                    .transition(.opacity)
            }

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
            wireCoordinator()
            coordinator.startupTimeout = usesQuickStartupTimeout ? 15 : 40
            clock.reset()
            coordinator.configure(media: media)
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            hoverHideTask?.cancel()
            reconnector.cancel()
            coordinator.tearDown()
        }
        .onChange(of: coordinator.isPlaying) { _, _ in
            resetHideTimer()
        }
        .onChange(of: coordinator.hasStartedPlayback) { _, started in
            // Once the first frame lands the controls become eligible; start the
            // auto-hide countdown so they don't linger.
            if started { resetHideTimer() }
        }
        .onChange(of: scenePhase) { _, phase in
            // The Home button backgrounds the app without calling onDisappear,
            // so pause here to stop audio when the player loses focus.
            if phase != .active, coordinator.isPlaying { coordinator.togglePlay() }
        }
        .onChange(of: media) { _, newMedia in
            // The host swapped the stream (e.g. a new episode). Reset local
            // scrubbing state and hand the new media to the engine.
            isSeeking = false
            seekPosition = 0
            isPanelOpen = false
            loadFailed = false
            reconnector.reset()
            clock.reset()
            coordinator.configure(media: newMedia)
            resetHideTimer()
        }
        .onChange(of: isControlsVisible) { _, visible in
            #if os(tvOS)
                // Hand focus to the tap-catcher once the controls vanish so the
                // remote can bring them back.
                if !visible { Task { @MainActor in catcherFocused = true } }
            #endif
        }
        // Handle the Menu/back button at the player root so it reliably overrides
        // the fullScreenCover's default dismiss-on-Menu.
        .onMenuPress { handleMenuPress() }
        // The Siri Remote's dedicated Play/Pause button is a distinct press type
        // from a click-pad Select, so the on-screen button never sees it.
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

    // MARK: - Coordinator wiring

    private func wireCoordinator() {
        coordinator.onTime = { current, duration in
            if !isSeeking, current.isFinite { clock.current = current }
            if duration.isFinite, duration > 0 { clock.duration = duration }
        }
        coordinator.onPlaybackFailure = {
            Logger.player.error("LumeEngine startup failure → \(reportsStartupFailure && !coordinator.hasStartedPlayback ? "falling back to next engine" : "failure overlay", privacy: .public)")
            reportFailure()
        }
        coordinator.onStalled = {
            // Mid-stream drop: bounded exponential backoff, then give up loudly.
            if reconnector.hasGivenUp {
                Logger.player.error("LumeEngine stall retries exhausted → failure overlay")
                withAnimation(.easeInOut(duration: 0.25)) { loadFailed = true }
            } else {
                Logger.player.warning("LumeEngine stalled → scheduling engine reload")
                reconnector.scheduleRetry { coordinator.reload() }
            }
        }
        coordinator.onRecovered = { reconnector.reset() }
    }

    // MARK: - Tap Catcher

    @ViewBuilder
    private var tapCatcher: some View {
        #if os(tvOS)
            // tvOS has no touch surface: drive the overlay from the Siri remote.
            // The catcher only takes focus while controls are hidden, so the
            // control buttons stay reachable otherwise.
            Button(action: showControls) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(InvisibleButtonStyle())
            // Yield focus to the failure overlay's buttons when a stream dies.
            .disabled(isControlsVisible || isChannelBrowserOpen || loadFailed)
            .focused($catcherFocused)
            .onMoveCommand { direction in
                // Watching live TV with the controls hidden, left opens the
                // channel browser, up/down surf adjacent channels and right
                // recalls the last channel watched. Any other move summons the
                // controls.
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
            LumeEngineControlsOverlay(
                coordinator: coordinator,
                media: media,
                isSeeking: $isSeeking,
                seekPosition: $seekPosition,
                clock: clock,
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
        /// channel watched just before this one. Falls back to summoning the
        /// controls when there's nothing to jump to.
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
        if reportsStartupFailure, !coordinator.hasStartedPlayback {
            onPlaybackFailed?()
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) { loadFailed = true }
    }

    /// Re-prepare the current stream after a failure (the Try Again button).
    private func retryPlayback() {
        withAnimation(.easeInOut(duration: 0.25)) { loadFailed = false }
        reconnector.reset()
        coordinator.reload()
    }
}

// MARK: - Engine-rendered subtitles

/// Draws the engine's active subtitle cues over the video. A leaf that observes
/// only the standalone `SubtitleCueModel`, so per-cue changes invalidate this
/// view alone — never the engine view above it, and never the controls overlay
/// (both of which observe the coordinator, whose `objectWillChange` therefore
/// no longer fires at tick rate). Keeping the cue text off the coordinator is
/// what stops an open track menu flickering and dropping taps.
private struct LumeEngineSubtitleOverlay: View {
    @ObservedObject var cues: SubtitleCueModel
    /// Lifts the cues above the controls' scrubber while they're showing.
    let controlsVisible: Bool

    var body: some View {
        if let text = cues.text, !text.isEmpty {
            VStack {
                Spacer()
                Text(text)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, controlsVisible ? 120 : 40)
            }
            .allowsHitTesting(false)
        }
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

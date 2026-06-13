import Combine
import KSPlayer
import OSLog
import SwiftData
import SwiftUI

/// KSPlayer-backed video host.
///
/// On tvOS it hosts the shared `TVPlayerControlsOverlay` — the very same
/// Apple-TV-style overlay the VLCKit engine uses — via the `KSTVPlaybackEngine`
/// adapter, so both engines present an identical player UI. On iOS / macOS it
/// layers its own Apple-style controls (`KSPlayerControlsOverlay`).
@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
struct KSPlayerEngineView: View {
    let media: PlayableMedia
    /// High-frequency playback clock, held as the `@Observable` object rather
    /// than as `@Binding` scalars. A `@Binding` whose root is an `@Observable`
    /// re-renders the *holding* view on every change — which rebuilt the controls
    /// overlay / menus on every playback tick. Holding the object and never
    /// reading `current`/`duration` in this body keeps the engine view off the
    /// tick path; only the scrubber leaf reads it. `@Bindable` so the iOS/macOS
    /// overlay can still take plain bindings.
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
    /// available — see `failPlayback`. The host advances to the next engine.
    var onPlaybackFailed: (() -> Void)?
    /// Invoked when the viewer picks a different stream (another episode, or a
    /// live channel via the Siri remote) from the in-player overlay. The host
    /// swaps `media` in response. tvOS only.
    var onSelectMedia: ((PlayableMedia) -> Void)?

    @StateObject var coordinator = KSVideoPlayer.Coordinator()
    /// Drives bounded backoff reconnects when the stream drops (see
    /// `handleState`). KSPlayer otherwise stops dead on a mid-stream failure.
    /// Non-private so the playback/reconnect logic in `KSPlayerEngineView+Playback`
    /// (and the dead-stream handling there) can reach it.
    @State var reconnector = PlaybackRetryController()
    @State private var isPlaying = false
    /// Initial-load gate. The engine sits in `.preparing` / `.buffering` for
    /// ~10–20s before the first frame (`.bufferFinished`); showing the normal
    /// controls — with their Play button — during that window made viewers think
    /// playback was paused and needed a press. The controls stay suppressed and
    /// a loading indicator shows until the stream first reaches `.bufferFinished`.
    @State var hasStartedPlayback = false
    /// True while the engine is preparing or (re)buffering, so the spinner shows
    /// both on first open and on a mid-stream stall.
    @State var isBuffering = true
    /// Last playhead position seen in `onPlay`, used to detect that frames are
    /// actually advancing. `-1` until the first sample. See `notePlaybackProgress`.
    @State var lastPlayhead: TimeInterval = -1
    /// Set once a dead stream is given up on — the initial load never produced a
    /// frame within `startupTimeout`, or the bounded reconnect budget was spent.
    /// Swaps the endless spinner for the `PlayerErrorIndicator` (Try Again / Back)
    /// so a stream that never starts no longer locks the player.
    @State var loadFailed = false
    /// Gate that ensures `markPlaybackStarted()` and the `.bufferFinished` path in
    /// `updateLoadingState` only fire after the current session has emitted its own
    /// `.readyToPlay`. A stale `.bufferFinished` from the previous session
    /// (arriving in the window after `retryPlayback()` resets `hasStartedPlayback`)
    /// would otherwise prematurely cancel the startup watchdog and clear the
    /// spinner before the new session is ready.
    @State var hasSeenReadyToPlay = false
    /// Fires `failPlayback()` if the stream hasn't produced a frame within
    /// `startupTimeout`. Covers a stream that hangs in `.preparing`/`.buffering`
    /// forever without ever emitting `.error` (so the reconnector never engages).
    @State var startupWatchdog: Task<Void, Never>?
    /// When a runaway live A/V clock split was first observed, `nil` while in
    /// sync (see `noteClockDrift` — frozen image with healthy audio after an
    /// HLS timestamp discontinuity).
    @State var driftSince: TimeInterval?
    /// When the last drift-triggered stream rebuild fired, for the re-fire
    /// cooldown in `noteClockDrift`.
    @State var lastDriftRecovery: TimeInterval = -.infinity
    /// Fires `retryPlayback()` if a live stream sits in `.buffering` for
    /// `stallTimeout` after playback had started. A mid-stream decode failure
    /// wedges KSPlayer in `.buffering` forever without ever emitting `.error`
    /// (so the reconnector never engages, and the startup watchdog is already
    /// disarmed). See `handleState`.
    @State var stallWatchdog: Task<Void, Never>?
    @State private var isControlsVisible = true
    @State var isSeeking = false
    @State private var seekPosition: TimeInterval = 0
    @State private var isPipActive = false
    @State var hideTask: Task<Void, Never>?
    @State private var hoverHideTask: Task<Void, Never>?

    #if os(tvOS)
        /// Republishes KSPlayer state to the shared overlay (`isPlaying`,
        /// `videoInfo`) and bridges its track / seek API.
        @StateObject var engine = KSTVPlaybackEngine()
        /// While an overlay panel (episodes / info) is open the controls must
        /// not auto-hide out from under the viewer.
        @State private var isPanelOpen = false
        /// Bumped to ask the overlay to close its open panel (Menu/back press).
        @State private var panelCloseToken = 0
        /// The channel-switching state below is `internal` (not `private`) so the
        /// extension in `KSPlayerEngineView+TVChannels.swift` can drive it.
        /// The full channel browser (categories + channels) raised by a left
        /// press while watching live TV with the controls hidden.
        @State var isChannelBrowserOpen = false
        /// Drives focus onto the transparent tap-catcher once the controls
        /// auto-hide, so the Siri remote can summon them again.
        @FocusState var catcherFocused: Bool
        /// Live-content sort the channel browser uses — so in-player channel
        /// surfing follows the same order the viewer saw in the list.
        @AppStorage(SortStorageKey.liveContent)
        var liveContentSortRaw: String = ContentSortOption.playlist.rawValue
        @Environment(\.modelContext) var modelContext
    #endif

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
        @Environment(\.dismissWindow) private var dismissWindow
    #endif

    private let autoHideInterval: TimeInterval = 4
    /// How long to wait for the first frame before declaring a stream dead. The
    /// engine legitimately sits in `.preparing`/`.buffering` for ~10–20s on a
    /// healthy open, so this is set well clear of that. The reconnect budget
    /// (~31s of bounded backoff) usually trips first on a stream that *errors*;
    /// this catches the one that simply never responds.
    let startupTimeout: TimeInterval = 40
    /// Shorter startup timeout used when a fallback engine is available: there's
    /// no point waiting the full `startupTimeout` on a black screen when another
    /// engine can be tried, so hand off after this if no frame has appeared.
    let fallbackStartupTimeout: TimeInterval = 15
    /// How long a live stream may sit in `.buffering` mid-playback before the
    /// stall watchdog rebuilds it. A healthy rebuffer only has to reach the
    /// live-buffer target (a few seconds), so 30s of no recovery means the
    /// pipeline is wedged, not catching up.
    let stallTimeout: TimeInterval = 30

    var body: some View {
        #if os(tvOS)
            tvBody
        #else
            standardBody
        #endif
    }

    // MARK: - tvOS body (shared overlay)

    #if os(tvOS)
        private var tvBody: some View {
            let options = makeOptions()
            return ZStack {
                Color.black
                    .ignoresSafeArea()

                KSVideoPlayer(coordinator: coordinator, url: media.url, options: options)
                    .onStateChanged { _, state in
                        // Defer all state mutations so they never run inside a
                        // SwiftUI view-update pass, which would trigger the
                        // "Modifying state during view update" / "Publishing
                        // changes from within view updates" runtime warnings.
                        DispatchQueue.main.async {
                            isPlaying = (state == .bufferFinished)
                            updateLoadingState(state)
                            engine.syncState(state)
                            handleState(state)
                        }
                    }
                    .onPlay { current, total in
                        // Defer for the same reason as onStateChanged; also
                        // prevents rapid back-to-back transitions (e.g.
                        // bufferFinished → buffering) from publishing two
                        // @ObservableObject changes in the same SwiftUI frame,
                        // which triggers "onChange updated multiple times per
                        // frame" warnings.
                        DispatchQueue.main.async {
                            if !isSeeking {
                                if current.isFinite { clock.current = current }
                                if total.isFinite, total > 0 { clock.duration = total }
                            }
                            notePlaybackProgress(current)
                            noteClockDrift()
                            // syncState (onStateChanged) already refreshes this
                            // on every transition; only chase it from the
                            // per-tick play callback until it first lands, so
                            // steady playback doesn't re-read tracks/codec each
                            // tick.
                            if engine.videoInfo == nil { engine.refreshVideoInfo() }
                        }
                    }
                    .ignoresSafeArea()

                tapCatcher

                // Suppress the controls (and their Play button) until the stream
                // has actually started, so viewers see a loading indicator
                // instead of a player that looks paused.
                if isControlsVisible, hasStartedPlayback, !loadFailed {
                    TVPlayerControlsOverlay(
                        coordinator: engine,
                        media: media,
                        clock: clock,
                        panelCloseToken: panelCloseToken,
                        onTogglePlay: { togglePlay() },
                        onResetHideTimer: { resetHideTimer() },
                        onSelectMedia: { onSelectMedia?($0) },
                        onPanelOpenChange: { setPanelOpen($0) },
                        onSwitchChannel: { switchLiveChannel($0) }
                    )
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

                skipIntroOverlay(controlsVisible: isControlsVisible) { time in
                    engine.seek(to: time)
                    // The skip button held focus; hand it back to the tap-catcher
                    // so the remote keeps summoning controls.
                    Task { @MainActor in catcherFocused = true }
                }

                if isChannelBrowserOpen {
                    channelBrowser
                }

                if isBuffering {
                    PlayerLoadingIndicator(title: hasStartedPlayback ? nil : media.title)
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
                engine.attach(coordinator: coordinator)
                scheduleHide()
                startStartupWatchdog()
            }
            .onDisappear {
                hideTask?.cancel()
                reconnector.cancel()
                cancelStartupWatchdog()
                cancelStallWatchdog()
                coordinator.resetPlayer()
            }
            .onChange(of: engine.isPlaying) { _, _ in
                resetHideTimer()
            }
            .onChange(of: scenePhase) { _, phase in
                // The Home button backgrounds the app without calling
                // onDisappear, so pause here to stop audio when the player
                // loses focus.
                if phase != .active { coordinator.playerLayer?.pause() }
            }
            .onChange(of: media) { _, _ in
                // The host swapped the stream (KSPlayer reloads its URL
                // automatically). Reset local scrubbing / panel state.
                isSeeking = false
                seekPosition = 0
                isPanelOpen = false
                hasStartedPlayback = false
                hasSeenReadyToPlay = false
                isBuffering = true
                loadFailed = false
                lastPlayhead = -1
                driftSince = nil
                lastDriftRecovery = -.infinity
                cancelStallWatchdog()
                reconnector.reset()
                engine.reset()
                startStartupWatchdog()
                resetHideTimer()
            }
            .onChange(of: isControlsVisible) { _, visible in
                // Hand focus to the tap-catcher once the controls vanish so the
                // remote can bring them back.
                if !visible { Task { @MainActor in catcherFocused = true } }
            }
            // Handle Menu/back at the player root so it reliably overrides the
            // cover's default dismiss-on-Menu.
            .onExitCommand { handleMenuPress() }
            // The Siri Remote's dedicated Play/Pause button is a distinct press
            // type from a click-pad Select, so the on-screen button never sees
            // it. Drive togglePlay() explicitly, otherwise the press falls
            // through to KSPlayer's own handling, which pauses but won't resume.
            .onPlayPauseCommand { togglePlay() }
        }

        private var tapCatcher: some View {
            // tvOS has no touch surface: drive the overlay from the Siri remote.
            // The catcher only takes focus while controls are hidden, so the
            // control buttons stay reachable otherwise.
            Button(action: showControls) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(KSInvisibleButtonStyle())
            // Yield focus to the failure overlay's buttons when a stream dies.
            .disabled(isControlsVisible || isChannelBrowserOpen || loadFailed)
            .focused($catcherFocused)
            .onMoveCommand { direction in
                // Watching live TV with the controls hidden, left opens the
                // channel browser, up/down surf adjacent channels and right
                // recalls the last channel watched. Any other move summons
                // the controls.
                if media.isLive, direction == .left {
                    openChannelBrowser()
                } else if media.isLive, direction == .up || direction == .down || direction == .right {
                    switchLiveChannel(direction)
                } else {
                    showControls()
                }
            }
        }

        func showControls() {
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

        private func handleMenuPress() {
            if loadFailed {
                closePlayer()
            } else if isChannelBrowserOpen {
                closeChannelBrowser()
            } else if isPanelOpen {
                panelCloseToken += 1
            } else if isControlsVisible {
                hideControls()
            } else {
                closePlayer()
            }
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
    #endif

    // MARK: - iOS / macOS body (own controls)

    #if !os(tvOS)
        private var standardBody: some View {
            let options = makeOptions()
            return ZStack {
                KSVideoPlayer(coordinator: coordinator, url: media.url, options: options)
                    .onStateChanged { _, state in
                        DispatchQueue.main.async {
                            isPlaying = (state == .bufferFinished)
                            updateLoadingState(state)
                            handleState(state)
                        }
                    }
                    .onPlay { current, total in
                        DispatchQueue.main.async {
                            if !isSeeking {
                                if current.isFinite { clock.current = current }
                                if total.isFinite, total > 0 { clock.duration = total }
                            }
                            notePlaybackProgress(current)
                            noteClockDrift()
                        }
                    }
                    .ignoresSafeArea()

                // Hold the controls back until the stream starts, so the loading
                // indicator stands in for a player that would otherwise look
                // paused behind its Play button.
                if isControlsVisible, hasStartedPlayback, !loadFailed {
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

                skipIntroOverlay(controlsVisible: isControlsVisible) { coordinator.seek(time: $0) }

                if isBuffering {
                    PlayerLoadingIndicator(title: hasStartedPlayback ? nil : media.title)
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
                scheduleHide()
                observePipState()
                startStartupWatchdog()
            }
            .onDisappear {
                hideTask?.cancel()
                hoverHideTask?.cancel()
                reconnector.cancel()
                cancelStartupWatchdog()
                cancelStallWatchdog()
                coordinator.resetPlayer()
            }
            .onTapGesture {
                toggleControls()
            }
            #if os(macOS)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active:
                    if !isControlsVisible {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isControlsVisible = true
                        }
                    }
                    resetHideTimer()
                    hoverHideTask?.cancel()
                case .ended:
                    hoverHideTask?.cancel()
                    hoverHideTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isControlsVisible = false
                        }
                    }
                }
            }
            .onKeyPress(.leftArrow) { coordinator.skip(interval: -15); resetHideTimer(); return .handled }
            .onKeyPress(.rightArrow) { coordinator.skip(interval: 15); resetHideTimer(); return .handled }
            .onKeyPress(.space) { togglePlay(); return .handled }
            .onKeyPress(.escape) { closePlayer(); return .handled }
            #endif
        }

        private var controlsOverlay: some View {
            KSPlayerControlsOverlay(
                coordinator: coordinator,
                media: media,
                isPlaying: $isPlaying,
                isSeeking: $isSeeking,
                seekPosition: $seekPosition,
                currentTime: $clock.current,
                duration: $clock.duration,
                isPipActive: $isPipActive,
                hideTask: $hideTask,
                onClose: { closePlayer() },
                onTogglePlay: { togglePlay() },
                onResetHideTimer: { resetHideTimer() },
                onScheduleHide: { scheduleHide() }
            )
        }

        private func toggleControls() {
            withAnimation(.easeInOut(duration: 0.2)) {
                isControlsVisible.toggle()
            }
            if isControlsVisible {
                scheduleHide()
            }
        }

        // MARK: PiP

        private func observePipState() {
            // Poll until playerLayer is available, then observe its published isPipActive
            Task { @MainActor in
                var attempts = 0
                while coordinator.playerLayer == nil, attempts < 50 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    attempts += 1
                }
                guard let playerLayer = coordinator.playerLayer else { return }
                for await active in playerLayer.$isPipActive.values {
                    isPipActive = active
                }
            }
        }
    #endif

    // MARK: - Actions (shared)

    private func togglePlay() {
        let playing: Bool
        #if os(tvOS)
            playing = engine.isPlaying
        #else
            playing = isPlaying
        #endif
        if playing {
            coordinator.playerLayer?.pause()
        } else {
            coordinator.playerLayer?.play()
        }
        #if os(tvOS)
            // Reflect the new state immediately so the glyph flips without
            // waiting for the next state callback.
            engine.syncState(playing ? .paused : .bufferFinished)
        #endif
        resetHideTimer()
    }

    private func resetHideTimer() {
        hideTask?.cancel()
        if isControlsVisible {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        #if os(tvOS)
            guard engine.isPlaying, !isPanelOpen else { return }
        #else
            guard isPlaying else { return }
        #endif
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(autoHideInterval * 1_000_000_000))
            #if os(tvOS)
                guard !Task.isCancelled, engine.isPlaying else { return }
            #else
                guard !Task.isCancelled, isPlaying else { return }
            #endif
            withAnimation(.easeInOut(duration: 0.2)) {
                isControlsVisible = false
            }
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

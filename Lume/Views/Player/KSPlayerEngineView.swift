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
    /// High-frequency playback clock, threaded down as the `@Observable` object
    /// rather than as `@Binding` scalars. A `@Binding` whose root is an
    /// `@Observable` re-renders the *holding* view on every change — which
    /// rebuilt the controls overlay / menus on every playback tick (KSPlayer
    /// ticks at 10 Hz, and a re-rendering host makes an open `Menu` flicker and
    /// drop taps). Neither this body nor the overlay's reads `current` /
    /// `duration`; only the scrubber leaf does, so a tick invalidates nothing
    /// but that leaf.
    var clock: PlaybackClock
    let mediaSwapper: PlayerMediaSwapper
    /// The episode queued after `media`, resolved by the host. Drives the
    /// end-of-episode Next Up affordances; `nil` when there is nothing to play
    /// next.
    var nextUpMedia: PlayableMedia?
    /// Previous/next stream for the transport controls, resolved once per stream
    /// by the host: the surrounding episodes of a series, or the channels either
    /// side of a live one. `neighboursUnknown` means the catalog has no episode
    /// rows yet, which the controls render as disabled rather than absent.
    var itemNeighbours = PlayerItemNavigation.Neighbours.none
    /// Intro / recap / outro windows for the active episode (from IntroDB). The
    /// openers drive the in-player Skip Intro button; the outro sets when the
    /// Next Episode button arms. `nil` when IntroDB knows nothing about it.
    var skipSegments: IntroSegments?
    /// When true, an initial-load failure reports to the host via
    /// `onPlaybackFailed` (which decides what to try next) instead of raising
    /// this engine's own error overlay — see `failPlayback`.
    var reportsStartupFailure = false
    /// Use the shorter fallback startup window before declaring failure, so a
    /// switch to the next engine is prompt. Off for attempts that should wait
    /// out the full startup timeout.
    var usesQuickStartupTimeout = false
    /// Invoked on an initial-load failure when `reportsStartupFailure` is set.
    var onPlaybackFailed: (() -> Void)?
    /// Invoked when the viewer picks a different stream (another episode, or a
    /// live channel via the Siri remote) from the in-player overlay. The host
    /// swaps `media` in response. tvOS only.
    var onSelectMedia: ((PlayableMedia) -> Void)?
    /// Invoked when an explicit "next episode" press leaves the current episode
    /// behind, so the host can mark it watched and scrobble it. The press is
    /// available from the first frame, below the completion line the automatic
    /// advance relies on, so it has to say so itself.
    var onCompleteCurrentItem: (() -> Void)?
    /// What the lock screen's next/previous track buttons play, owned by the
    /// host and handed to `NowPlayingService` with this engine's transport.
    /// `nil` on tvOS, where the Siri Remote already owns stream changes.
    var onRemoteAdvance: ((PlayerMediaSwapper.Step) -> Bool)?

    @StateObject var coordinator = KSVideoPlayer.Coordinator()
    /// Drives bounded backoff reconnects when the stream drops (see
    /// `handleState`). KSPlayer otherwise stops dead on a mid-stream failure.
    /// Non-private so the playback/reconnect logic in `KSPlayerEngineView+Playback`
    /// (and the dead-stream handling there) can reach it.
    @State var reconnector = PlaybackRetryController()
    @State var isPlaying = false
    /// Initial-load gate. The engine sits in `.preparing` / `.buffering` for
    /// ~10–20s before the first frame (`.bufferFinished`); showing the normal
    /// controls — with their Play button — during that window made viewers think
    /// playback was paused and needed a press. The controls stay suppressed and
    /// a loading indicator shows until the stream first reaches `.bufferFinished`.
    @State var hasStartedPlayback = false
    /// True while the engine is preparing or (re)buffering, so the spinner shows
    /// both on first open and on a mid-stream stall.
    @State var isBuffering = true
    /// Per-tick bookkeeping for the 10 Hz `onPlay` callback (progress detection
    /// and the clock-drift watchdog). A reference type held in `@State` on
    /// purpose: mutating its properties — unlike writing `@State` scalars —
    /// does not invalidate this view. Keeping `lastPlayhead` as `@State`
    /// re-rendered the whole engine view (and with it the controls overlay and
    /// any open track menu) ten times a second.
    @State var tick = PlaybackTickScratch()
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
    /// Fires `retryPlayback()` if a live stream sits in `.buffering` for
    /// `stallTimeout` after playback had started. A mid-stream decode failure
    /// wedges KSPlayer in `.buffering` forever without ever emitting `.error`
    /// (so the reconnector never engages, and the startup watchdog is already
    /// disarmed). See `handleState`.
    @State var stallWatchdog: Task<Void, Never>?
    @State var isControlsVisible = true
    /// Presents the OpenSubtitles browser. Held here rather than in the controls
    /// overlay: the overlay is removed when the controls auto-hide, which would
    /// take a sheet anchored there down with it mid-search.
    @State var isSearchingSubtitles = false
    @State var isSeeking = false
    @State var seekPosition: TimeInterval = 0
    /// PiP state and its observer task are `internal` (not `private`) so the
    /// PiP observation in `KSPlayerEngineView+Playback.swift` can drive them.
    @State var isPipActive = false
    @State var hideTask: Task<Void, Never>?
    @State private var hoverHideTask: Task<Void, Never>?
    @State var pipObservationTask: Task<Void, Never>?
    #if os(macOS)
        /// Drives PiP on macOS in place of the layer's `isPipActive`, whose
        /// delegate leaves the PiP window's buttons dead there.
        @State var macPip = KSMacPictureInPicture()
    #endif
    // Serialises stream changes for this session — the Siri remote's channel
    // surfing and the on-screen transport controls share it, so two swaps can
    // never be in flight at once. `internal` so the channel switching in
    // `KSPlayerEngineView+TVChannels.swift` can reach it; never read from a body.

    #if os(tvOS)
        /// Republishes KSPlayer state to the shared overlay (`isPlaying`,
        /// `videoInfo`) and bridges its track / seek API.
        @StateObject var engine = KSTVPlaybackEngine()
        /// While an overlay panel (episodes / info) is open the controls must
        /// not auto-hide out from under the viewer.
        @State var isPanelOpen = false
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
        /// Keeps channel surfing inside what this viewer may watch — a child
        /// profile must not be able to rock up/down, or recall the last channel,
        /// into a category a parent locked or the user hid.
        @Environment(\.contentRestriction) var restriction
    #endif

    #if !os(tvOS)
        /// Video-track snapshot for the stream-info caption — see `+StreamInfo`.
        @State var videoInfo: PlayerVideoInfo?
    #endif

    // `dismiss` / `dismissWindow` / `autoHideInterval` are internal so the shared
    // transport actions in `KSPlayerEngineView+Actions.swift` can reach them.
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
        @Environment(\.dismissWindow) var dismissWindow
    #endif

    let autoHideInterval: TimeInterval = 4
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
                                if current.isFinite {
                                    clock.current = current
                                }
                                if total.isFinite, total > 0 {
                                    clock.duration = total
                                }
                            }
                            notePlaybackProgress(current)
                            noteClockDrift()
                            // syncState (onStateChanged) already refreshes this
                            // on every transition; only chase it from the
                            // per-tick play callback until it first lands, so
                            // steady playback doesn't re-read tracks/codec each
                            // tick.
                            if engine.videoInfo == nil {
                                engine.refreshVideoInfo()
                            }
                        }
                    }
                    .ignoresSafeArea()

                // KSPlayer decodes the selected subtitle into
                // `subtitleModel.parts`, but the bare `KSVideoPlayer` above draws
                // only video — this overlay renders those parts on screen.
                KSSubtitleOverlay(subtitleModel: coordinator.subtitleModel)

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
                        onSwitchChannel: { switchLiveChannel($0) },
                        mediaSwapper: mediaSwapper, onCompleteCurrentItem: { onCompleteCurrentItem?() },
                        onSearchSubtitles: subtitleSearchAction
                    )
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }

                episodeOverlays(controlsVisible: isControlsVisible) { time in
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
            .subtitleSearch(isPresented: $isSearchingSubtitles, media: media, onPick: applyExternalSubtitle)
            .preferredColorScheme(.dark)
            .onAppear {
                engine.attach(coordinator: coordinator)
                attachNowPlayingTransport()
                scheduleHide()
                startStartupWatchdog()
            }
            .onDisappear {
                hideTask?.cancel()
                reconnector.cancel()
                cancelStartupWatchdog()
                cancelStallWatchdog()
                PlaybackQoE.shared.endSession()
                NowPlayingService.shared.detachTransport(owner: coordinator)
                coordinator.resetPlayer()
            }
            .onChange(of: engine.isPlaying) { _, _ in
                resetHideTimer()
            }
            .onChange(of: scenePhase) { _, phase in
                // The Home button backgrounds the app without calling
                // onDisappear, so pause here to stop audio when the player
                // loses focus.
                if phase != .active {
                    coordinator.playerLayer?.pause()
                }
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
                tick.reset()
                cancelStallWatchdog()
                reconnector.reset()
                engine.reset()
                startStartupWatchdog()
                resetHideTimer()
            }
            .onChange(of: isControlsVisible) { _, visible in
                // Hand focus to the tap-catcher once the controls vanish so the
                // remote can bring them back.
                if !visible {
                    Task { @MainActor in catcherFocused = true }
                }
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
            .tvRemoteMoveCommand { direction in
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
                            refreshVideoInfo()
                            handleState(state)
                        }
                    }
                    .onPlay { current, total in
                        DispatchQueue.main.async {
                            if !isSeeking {
                                if current.isFinite {
                                    clock.current = current
                                }
                                if total.isFinite, total > 0 {
                                    clock.duration = total
                                }
                            }
                            notePlaybackProgress(current)
                            noteClockDrift()
                            chaseVideoInfo()
                        }
                    }
                    .ignoresSafeArea()

                // KSPlayer decodes the selected subtitle into
                // `subtitleModel.parts`, but the bare `KSVideoPlayer` above draws
                // only video — this overlay renders those parts on screen.
                KSSubtitleOverlay(subtitleModel: coordinator.subtitleModel)

                // Hold the controls back until the stream starts, so the loading
                // indicator stands in for a player that would otherwise look
                // paused behind its Play button.
                if isControlsVisible, hasStartedPlayback, !loadFailed {
                    controlsOverlay
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }

                episodeOverlays(controlsVisible: isControlsVisible) { coordinator.seek(time: $0) }

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
            .subtitleSearch(isPresented: $isSearchingSubtitles, media: media, onPick: applyExternalSubtitle)
            .preferredColorScheme(.dark)
            .onAppear {
                attachNowPlayingTransport()
                scheduleHide()
                observePipState()
                startStartupWatchdog()
            }
            .onDisappear {
                hideTask?.cancel()
                hoverHideTask?.cancel()
                pipObservationTask?.cancel()
                #if os(macOS)
                    macPip.stop(restoringWindow: false)
                #endif
                reconnector.cancel()
                cancelStartupWatchdog()
                cancelStallWatchdog()
                PlaybackQoE.shared.endSession()
                NowPlayingService.shared.detachTransport(owner: coordinator)
                coordinator.resetPlayer()
            }
            .onChange(of: media.id) { _, _ in
                resetVideoInfo()
                // An in-player swap reuses the KSPlayerLayer but re-prepares it;
                // re-arm the observation so the task can never be left awaiting a
                // publisher the swap has finished with (it holds the layer — and
                // its decoder session — strongly for as long as it runs).
                observePipState()
            }
            .onTapGesture {
                toggleControls()
            }
            #if os(macOS)
            .onChange(of: macPip.isActive) { _, active in isPipActive = active }
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
            .liveChannelKeyNavigation(
                neighbours: itemNeighbours, swapper: mediaSwapper,
                onSelect: { onSelectMedia?($0) }, onResetHideTimer: resetHideTimer
            )
            .onKeyPress(.space) { togglePlay(); return .handled }
            .onKeyPress(.escape) { closePlayer(); return .handled }
            #endif
        }

    #endif
}

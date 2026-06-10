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
    /// Invoked when the viewer picks a different stream (another episode, or a
    /// live channel via the Siri remote) from the in-player overlay. The host
    /// swaps `media` in response. tvOS only.
    var onSelectMedia: ((PlayableMedia) -> Void)?

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    /// Drives bounded backoff reconnects when the stream drops (see
    /// `handleState`). KSPlayer otherwise stops dead on a mid-stream failure.
    @State private var reconnector = PlaybackRetryController()
    @State private var isPlaying = false
    /// Initial-load gate. The engine sits in `.preparing` / `.buffering` for
    /// ~10–20s before the first frame (`.bufferFinished`); showing the normal
    /// controls — with their Play button — during that window made viewers think
    /// playback was paused and needed a press. The controls stay suppressed and
    /// a loading indicator shows until the stream first reaches `.bufferFinished`.
    @State private var hasStartedPlayback = false
    /// True while the engine is preparing or (re)buffering, so the spinner shows
    /// both on first open and on a mid-stream stall.
    @State private var isBuffering = true
    @State private var isControlsVisible = true
    @State private var isSeeking = false
    @State private var seekPosition: TimeInterval = 0
    @State private var isPipActive = false
    @State private var hideTask: Task<Void, Never>?
    @State private var hoverHideTask: Task<Void, Never>?

    #if os(tvOS)
        /// Republishes KSPlayer state to the shared overlay (`isPlaying`,
        /// `videoInfo`) and bridges its track / seek API.
        @StateObject private var engine = KSTVPlaybackEngine()
        /// While an overlay panel (episodes / info) is open the controls must
        /// not auto-hide out from under the viewer.
        @State private var isPanelOpen = false
        /// Bumped to ask the overlay to close its open panel (Menu/back press).
        @State private var panelCloseToken = 0
        /// Drives focus onto the transparent tap-catcher once the controls
        /// auto-hide, so the Siri remote can summon them again.
        @FocusState private var catcherFocused: Bool
        /// Live-content sort the channel browser uses — so in-player channel
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
                        isPlaying = (state == .bufferFinished)
                        updateLoadingState(state)
                        engine.syncState(state)
                        handleState(state)
                    }
                    .onPlay { current, total in
                        if !isSeeking {
                            if current.isFinite { clock.current = current }
                            if total.isFinite, total > 0 { clock.duration = total }
                        }
                        // syncState (onStateChanged) already refreshes this on
                        // every transition; only chase it from the per-tick play
                        // callback until it first lands, so steady playback
                        // doesn't re-read tracks/codec each tick.
                        if engine.videoInfo == nil { engine.refreshVideoInfo() }
                    }
                    .ignoresSafeArea()

                tapCatcher

                // Suppress the controls (and their Play button) until the stream
                // has actually started, so viewers see a loading indicator
                // instead of a player that looks paused.
                if isControlsVisible, hasStartedPlayback {
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

                if isBuffering {
                    PlayerLoadingIndicator(title: hasStartedPlayback ? nil : media.title)
                        .transition(.opacity)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                engine.attach(coordinator: coordinator)
                scheduleHide()
            }
            .onDisappear {
                hideTask?.cancel()
                reconnector.cancel()
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
                isBuffering = true
                reconnector.reset()
                engine.reset()
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
            .disabled(isControlsVisible)
            .focused($catcherFocused)
            .onMoveCommand { direction in
                // Watching live TV with the controls hidden, up/down surf
                // adjacent channels and right recalls the last channel watched.
                // Any other move summons the controls.
                if media.isLive, direction == .up || direction == .down || direction == .right {
                    switchLiveChannel(direction)
                } else {
                    showControls()
                }
            }
        }

        /// Change the live channel from the Siri Remote: up/down surf to the
        /// adjacent channel (a TV remote's channel rocker), while right recalls
        /// the channel watched just before this one (the remote's "last"
        /// button). Falls back to summoning the controls when there's nothing
        /// to jump to.
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

        private func handleMenuPress() {
            if isPanelOpen {
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
                        isPlaying = (state == .bufferFinished)
                        updateLoadingState(state)
                        handleState(state)
                    }
                    .onPlay { current, total in
                        if !isSeeking {
                            if current.isFinite { clock.current = current }
                            if total.isFinite, total > 0 { clock.duration = total }
                        }
                    }
                    .ignoresSafeArea()

                // Hold the controls back until the stream starts, so the loading
                // indicator stands in for a player that would otherwise look
                // paused behind its Play button.
                if isControlsVisible, hasStartedPlayback {
                    controlsOverlay
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }

                if isBuffering {
                    PlayerLoadingIndicator(title: hasStartedPlayback ? nil : media.title)
                        .transition(.opacity)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                scheduleHide()
                observePipState()
            }
            .onDisappear {
                hideTask?.cancel()
                hoverHideTask?.cancel()
                reconnector.cancel()
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

    // MARK: - Loading state (shared)

    /// Drive the loading indicator + initial controls gate off KSPlayer's state.
    /// `.bufferFinished` is the first frame actually playing, so it both clears
    /// the spinner and unlocks the controls for good; a later `.buffering` (a
    /// mid-stream stall) re-shows the spinner without re-hiding the controls.
    private func updateLoadingState(_ state: KSPlayerState) {
        switch state {
        case .initialized, .preparing, .readyToPlay, .buffering:
            if !isBuffering {
                withAnimation(.easeInOut(duration: 0.25)) { isBuffering = true }
            }
        case .bufferFinished:
            if !hasStartedPlayback { hasStartedPlayback = true }
            if isBuffering {
                withAnimation(.easeInOut(duration: 0.25)) { isBuffering = false }
            }
        case .paused, .playedToTheEnd:
            if isBuffering {
                withAnimation(.easeInOut(duration: 0.25)) { isBuffering = false }
            }
        case .error:
            // Leave the spinner as-is: a drop during initial load keeps spinning
            // through the bounded reconnect (which returns to `.preparing`).
            break
        }
    }

    // MARK: - Reconnect (shared)

    /// React to a KSPlayer state change for reconnect purposes. A mid-stream
    /// failure lands the layer in `.error` and it sits there frozen; we drive a
    /// bounded backoff reconnect off that, and clear the budget once playback is
    /// confirmed healthy again. `.playedToTheEnd` is a clean finish, not a drop,
    /// so it is left alone.
    private func handleState(_ state: KSPlayerState) {
        switch state {
        case .readyToPlay, .bufferFinished:
            reconnector.reset()
        case .error:
            reconnector.scheduleRetry { reconnect() }
        default:
            break
        }
    }

    /// Re-prepare the current stream in place. `KSPlayerLayer.play()` calls
    /// `prepareToPlay()` whenever the layer is in `.error`, which rebuilds the
    /// input from scratch. VOD resumes near the drop point via `startPlayTime`
    /// (re-read on each prepare); live rejoins the live edge.
    private func reconnect() {
        guard let layer = coordinator.playerLayer else { return }
        if !media.isLive, clock.current > 1 {
            layer.options.startPlayTime = clock.current
        }
        Logger.player.log("reconnect: reloading KSPlayer stream")
        layer.play()
    }

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

// MARK: - Options

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
private extension KSPlayerEngineView {
    /// Process-wide KSPlayer configuration, applied exactly once on first
    /// access (static `let` init is lazy and thread-safe). These are global
    /// settings, so assigning them on every `makeOptions()` call was a needless
    /// side effect from a view body.
    static let configureGlobalOptions: Void = {
        KSOptions.secondPlayerType = KSMEPlayer.self
        KSOptions.isAutoPlay = true
        KSOptions.isPipPopViewController = false

        #if DEBUG
            KSOptions.logLevel = .warning
        #else
            KSOptions.logLevel = .error
        #endif
    }()

    func makeOptions() -> KSOptions {
        _ = Self.configureGlobalOptions

        let settings = KSPlayerOptions.load()
        // System-proxy use is a process-wide static with no per-instance
        // counterpart, so it's applied on the type each time.
        KSOptions.useSystemHTTPProxy = settings.systemProxy

        let options = KSOptions()
        options.hardwareDecode = settings.hardwareDecode
        options.asynchronousDecompression = settings.asyncDecompression
        options.isSecondOpen = settings.secondOpen
        options.isAccurateSeek = settings.accurateSeek
        options.isLoopPlay = settings.loopPlay
        options.autoDeInterlace = settings.autoDeinterlace
        options.autoRotate = settings.autoRotate
        options.videoAdaptable = settings.adaptive
        options.nobuffer = settings.noBuffer
        options.codecLowDelay = settings.codecLowDelay
        options.canStartPictureInPictureAutomaticallyFromInline = settings.autoPip
        options.maxBufferDuration = Double(settings.maxBuffer)
        options.preferredForwardBufferDuration = Double(media.isLive ? settings.liveBuffer : settings.vodBuffer)
        if !media.isLive, media.startTime > 1 {
            options.startPlayTime = media.startTime
        }
        #if os(macOS)
            options.automaticWindowResize = false
        #endif
        return options
    }
}

#if os(tvOS)
    /// Draws only its (clear) label — no focus highlight, scale or background —
    /// so the full-screen tap-catcher stays invisible even while it holds focus
    /// with the controls hidden.
    private struct KSInvisibleButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
        }
    }
#endif

#Preview("Fallback") {
    KSPlayerEngineView(
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

import SwiftData
import SwiftUI

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
#endif

#if !os(visionOS)
    /// AetherEngine video host with the shared Apple-style player controls.
    ///
    /// On tvOS it hosts the shared `TVPlayerControlsOverlay` (the coordinator
    /// conforms to `TVPlaybackEngine`), so every engine presents an identical player UI. On
    /// iOS / macOS it layers `EngineControlsOverlay`. Subtitle cues are
    /// drawn here above the video surface.
    struct AetherEngineEngineView: View {
        let media: PlayableMedia
        /// Held as the `@Observable` object, never read in this body: binding its
        /// tick-driven values would re-render the controls overlay every tick.
        @Bindable var clock: PlaybackClock
        let mediaSwapper: PlayerMediaSwapper
        /// The episode queued after `media`; drives the Next Up affordances.
        var nextUpMedia: PlayableMedia?
        /// Previous/next stream for the transport controls, resolved by the host.
        var itemNeighbours = PlayerItemNavigation.Neighbours.none
        /// Intro / recap / outro windows for the active episode (IntroDB).
        var skipSegments: IntroSegments?
        /// When true, an initial-load failure goes to `onPlaybackFailed` (the
        /// host picks the next engine) instead of this view's error overlay.
        var reportsStartupFailure = false
        /// Gives up on startup sooner, so a switch to the next engine is prompt.
        var usesQuickStartupTimeout = false
        var onPlaybackFailed: (() -> Void)?
        /// The viewer picked another stream from the overlay; the host swaps
        /// `media` in response.
        var onSelectMedia: ((PlayableMedia) -> Void)?
        /// An explicit "next episode" press left the current one behind.
        var onCompleteCurrentItem: (() -> Void)?
        /// What the lock screen's next/previous track buttons play; `nil` on tvOS.
        var onRemoteAdvance: ((PlayerMediaSwapper.Step) -> Bool)?
        /// A fresh URL when the provider refused the current one (Stalker).
        var refreshStreamURL: (() async -> URL?)?

        @StateObject private var coordinator = AetherEngineCoordinator()
        @State private var reconnector = PlaybackRetryController()
        /// A reconnect waiting on `refreshStreamURL`; cancelled when the player
        /// goes away or the stream changes, so a late answer can't reopen it.
        @State private var urlRefresh: Task<Void, Never>?
        @State private var isControlsVisible = true
        /// Held here, not in the overlay: the overlay goes away when the
        /// controls auto-hide and would take the sheet with it.
        @State private var isSearchingSubtitles = false
        @State private var loadFailed = false
        @State private var isSeeking = false
        @State private var seekPosition: TimeInterval = 0
        @State private var hideTask: Task<Void, Never>?
        @State private var isPanelOpen = false
        /// Bumped to ask the overlay to close its open panel (Menu/back press).
        @State private var panelCloseToken = 0
        @State private var episodeOverlayLink = PlayerEpisodeOverlayLink()
        #if os(tvOS)
            @State private var isChannelBrowserOpen = false
            /// Focus for the transparent tap-catcher once the controls hide, so
            /// the Siri Remote can summon them again.
            @FocusState private var catcherFocused: Bool
            @AppStorage(SortStorageKey.liveContent)
            private var liveContentSortRaw: String = ContentSortOption.playlist.rawValue
            @Environment(\.modelContext) private var modelContext
            /// Keeps channel surfing inside what this viewer may watch.
            @Environment(\.contentRestriction) private var restriction
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

                AetherEngineVideoSurface(videoView: coordinator.videoView)
                    .ignoresSafeArea()

                EngineSubtitleCueOverlay(cues: coordinator.subtitleCues, controlsVisible: isControlsVisible)

                // Catches taps over the engine's view, which would otherwise
                // swallow them before SwiftUI's gesture sees them.
                tapCatcher
                    .ignoresSafeArea()

                if isControlsVisible, coordinator.hasStartedPlayback, !loadFailed {
                    controlsOverlay
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }

                PlayerEpisodeOverlays(
                    segments: skipSegments,
                    nextUpMedia: nextUpMedia,
                    clock: clock,
                    controlsVisible: isControlsVisible,
                    link: episodeOverlayLink,
                    onSeek: { time in
                        coordinator.seek(to: time)
                        #if os(tvOS)
                            Task { @MainActor in catcherFocused = true }
                        #endif
                    },
                    onSelectMedia: { onSelectMedia?($0) }
                )

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
            .subtitleSearch(isPresented: $isSearchingSubtitles, media: media) { subtitle in
                coordinator.loadExternalSubtitle(subtitle)
            }
            .preferredColorScheme(.dark)
            .nowPlayingTransport(coordinator, advance: onRemoteAdvance)
            .onAppear {
                wireCoordinator()
                coordinator.startupTimeout = usesQuickStartupTimeout
                    ? AetherEngineCoordinator.quickStartupTimeout
                    : AetherEngineCoordinator.defaultStartupTimeout
                clock.reset()
                coordinator.configure(media: media)
                scheduleHide()
            }
            .onDisappear {
                hideTask?.cancel()
                reconnector.cancel()
                urlRefresh?.cancel()
                coordinator.tearDown()
            }
            .onChange(of: coordinator.isPlaying) { _, _ in
                resetHideTimer()
            }
            .onChange(of: coordinator.hasStartedPlayback) { _, started in
                if started { resetHideTimer() }
            }
            .onChange(of: scenePhase) { _, phase in
                // Home backgrounds the app without onDisappear: stop the audio.
                if coordinator.isPlaying, PlayerBackgrounding.shouldPause(for: phase, pipActive: coordinator.isPipActive) {
                    coordinator.togglePlay()
                }
            }
            .onChange(of: media) { _, newMedia in
                isSeeking = false
                seekPosition = 0
                isPanelOpen = false
                loadFailed = false
                reconnector.reset()
                urlRefresh?.cancel()
                clock.reset()
                coordinator.configure(media: newMedia)
                resetHideTimer()
            }
            .onChange(of: isControlsVisible) { _, visible in
                #if os(tvOS)
                    if !visible { episodeOverlayLink.controlsDidHide { catcherFocused = true } }
                #endif
            }
            .onPreferenceChange(PlayerControlsBarHeightKey.self) { episodeOverlayLink.reportControlsBarHeight($0) }
            // At the player root so it overrides the fullScreenCover's own
            // dismiss-on-Menu.
            .onMenuPress { handleMenuPress() }
            .onPlayPausePress { togglePlay() }
            .aetherMacHosting(coordinator, isControlsVisible: $isControlsVisible, onActivity: resetHideTimer)
            .playerKeyboardShortcuts(PlayerKeyActions(
                togglePlay: togglePlay, skip: { coordinator.skip(by: $0) }, close: closePlayer,
                resetHideTimer: resetHideTimer, showControls: showControls,
                neighbours: itemNeighbours, swapper: mediaSwapper, selectMedia: { onSelectMedia?($0) }
            ))
        }

        // MARK: - Coordinator wiring

        private func wireCoordinator() {
            coordinator.onTime = { current, duration in
                if !isSeeking, current.isFinite { clock.current = current }
                if duration.isFinite, duration > 0 { clock.duration = duration }
            }
            #if os(iOS)
                coordinator.onPictureInPictureStop = {
                    PlayerBackgrounding.pictureInPictureDidStop { closePlayer() }
                }
            #endif
            coordinator.onPlaybackFailure = { reportFailure($0) }
            coordinator.onStalled = { reconnect(after: $0) }
            coordinator.onRecovered = { reconnector.reset() }
            coordinator.onAudioCodecs = { codecs in
                if codecs != clock.audioCodecs { clock.audioCodecs = codecs }
            }
        }

        // MARK: - Failures

        /// Mid-stream drop: bounded backoff, then give up loudly.
        private func reconnect(after failure: AetherEngineFailure) {
            let showsFailure = reconnector.reconnect(
                after: failure,
                engine: "AetherEngine",
                refreshStreamURL: refreshStreamURL,
                holdURLRefresh: { urlRefresh = $0 },
                reload: { coordinator.reload(replacingURL: $0) }
            )
            if showsFailure { showFailure() }
        }

        /// The stream never started: the next engine, or the failure overlay.
        private func reportFailure(_ failure: AetherEngineFailure) {
            guard !loadFailed else { return }
            if failure.handsOffStartupFailure(
                engine: "AetherEngine",
                reportsStartupFailure: reportsStartupFailure,
                hasStartedPlayback: coordinator.hasStartedPlayback
            ) {
                onPlaybackFailed?()
                return
            }
            showFailure()
        }

        private func showFailure() {
            withAnimation(.easeInOut(duration: 0.25)) { loadFailed = true }
        }

        // MARK: - Tap Catcher

        @ViewBuilder
        private var tapCatcher: some View {
            #if os(tvOS)
                // Takes focus only while the controls are hidden, so the control
                // buttons stay reachable otherwise.
                Button(action: showControls) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(PlayerInvisibleButtonStyle())
                .disabled(isControlsVisible || isChannelBrowserOpen || loadFailed)
                .focused($catcherFocused)
                .tvRemoteMoveCommand { direction in
                    // Runs inside the focus engine's animated context: every
                    // layout or focus change it makes is deferred.
                    Task { @MainActor in handleMove(direction) }
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
                    onResetHideTimer: { PlayerControlsAutoHide.menuClosed(); resetHideTimer() },
                    onSelectMedia: { onSelectMedia?($0) },
                    onPanelOpenChange: { setPanelOpen($0) },
                    onSwitchChannel: { switchLiveChannel($0) },
                    mediaSwapper: mediaSwapper,
                    onCompleteCurrentItem: { onCompleteCurrentItem?() },
                    onSearchSubtitles: subtitleSearchAction
                )
            #else
                EngineControlsOverlay(
                    coordinator: coordinator,
                    engine: .aetherEngine,
                    media: media,
                    isSeeking: $isSeeking,
                    seekPosition: $seekPosition,
                    clock: clock,
                    hideTask: $hideTask,
                    onClose: { closePlayer() },
                    onTogglePlay: { togglePlay() },
                    onResetHideTimer: { PlayerControlsAutoHide.menuClosed(); resetHideTimer() },
                    onScheduleHide: { scheduleHide() },
                    onSearchSubtitles: subtitleSearchAction,
                    itemNeighbours: itemNeighbours,
                    onStepItem: { step in
                        mediaSwapper.step(
                            step,
                            in: itemNeighbours,
                            onCompleteCurrentItem: { onCompleteCurrentItem?() },
                            select: { onSelectMedia?($0) }
                        )
                    }
                )
            #endif
        }

        /// Raises the OpenSubtitles browser, or `nil` when this stream can't use it.
        private var subtitleSearchAction: (() -> Void)? {
            guard OpenSubtitlesService.supportsSearch(for: media) else { return nil }
            return { isSearchingSubtitles = true }
        }

        // MARK: - Actions

        private func togglePlay() {
            coordinator.togglePlay()
            resetHideTimer()
        }

        #if os(tvOS)
            /// With the controls hidden on live TV: left opens the channel
            /// browser, up/down surf, right recalls the last channel. Any other
            /// move summons the controls.
            private func handleMove(_ direction: MoveCommandDirection) {
                if media.isLive, direction == .left {
                    openChannelBrowser()
                } else if media.isLive, direction == .up || direction == .down || direction == .right {
                    switchLiveChannel(direction)
                } else {
                    showControls()
                }
            }

            private func switchLiveChannel(_ direction: MoveCommandDirection) {
                mediaSwapper.surf(
                    direction, from: media,
                    through: .init(
                        sortRaw: liveContentSortRaw, restriction: restriction, context: modelContext,
                        neighbours: itemNeighbours
                    ),
                    select: { onSelectMedia?($0) },
                    showControls: showControls
                )
            }

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

        private func hideControls() {
            hideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = false }
        }

        /// Menu/back: close the channel browser or an open panel first, then
        /// hide the controls, and only then dismiss the player.
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
            guard coordinator.isPlaying, !isPanelOpen, !PlayerControlsAutoHide.isSuppressed else { return }
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(autoHideInterval))
                if await PlayerControlsAutoHide.waitWhileMenuOpen() {
                    try? await Task.sleep(for: .seconds(autoHideInterval))
                }
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
                dismiss.dismissPlayer()
            #endif
        }

        /// The Try Again button: a fresh load of the current stream.
        private func retryPlayback() {
            withAnimation(.easeInOut(duration: 0.25)) { loadFailed = false }
            reconnector.reset()
            coordinator.reload()
        }
    }

    private extension View {
        /// macOS only: hover reveals the controls, and the app volume drives
        /// the engine.
        @ViewBuilder
        func aetherMacHosting(
            _ coordinator: AetherEngineCoordinator,
            isControlsVisible: Binding<Bool>,
            onActivity: @escaping () -> Void
        ) -> some View {
            #if os(macOS)
                playerHoverRevealsControls(isControlsVisible, onActivity: onActivity)
                    .playerVolume(coordinator)
            #else
                self
            #endif
        }
    }
#endif

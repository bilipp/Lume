import Combine
import KSPlayer
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
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval
    /// Invoked when the viewer picks a different stream (another episode, or a
    /// live channel via the Siri remote) from the in-player overlay. The host
    /// swaps `media` in response. tvOS only.
    var onSelectMedia: ((PlayableMedia) -> Void)?

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var isPlaying = false
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
                        engine.syncState(state)
                    }
                    .onPlay { current, total in
                        if !isSeeking {
                            if current.isFinite { currentTime = current }
                            if total.isFinite, total > 0 { duration = total }
                        }
                        engine.refreshVideoInfo()
                    }
                    .ignoresSafeArea()

                tapCatcher

                if isControlsVisible {
                    TVPlayerControlsOverlay(
                        coordinator: engine,
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
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                engine.attach(coordinator: coordinator)
                scheduleHide()
            }
            .onDisappear {
                hideTask?.cancel()
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
                // channels directly, and right jumps to the previous channel.
                // Any other move summons the controls.
                if media.isLive, direction == .up || direction == .down || direction == .right {
                    switchLiveChannel(direction)
                } else {
                    showControls()
                }
            }
        }

        /// Surf to the adjacent live channel — up selects the next channel, down
        /// (or right) the previous — matching a TV remote's channel rocker.
        private func switchLiveChannel(_ direction: MoveCommandDirection) {
            guard media.isLive else { return }
            let offset: Int
            switch direction {
            case .up: offset = 1
            case .down, .right: offset = -1
            default: return
            }
            let sort = ContentSortOption(rawValue: liveContentSortRaw) ?? .playlist
            guard let next = LiveChannelNavigator.adjacentMedia(
                for: media, offset: offset, sort: sort, in: modelContext
            ) else { return }
            onSelectMedia?(next)
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
                    }
                    .onPlay { current, total in
                        if !isSeeking {
                            if current.isFinite { currentTime = current }
                            if total.isFinite, total > 0 { duration = total }
                        }
                    }
                    .ignoresSafeArea()

                if isControlsVisible {
                    controlsOverlay
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
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
                currentTime: $currentTime,
                duration: $duration,
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

    // MARK: - Options

    private func makeOptions() -> KSOptions {
        KSOptions.secondPlayerType = KSMEPlayer.self
        KSOptions.isAutoPlay = true
        KSOptions.isPipPopViewController = false

        let options = KSOptions()
        options.canStartPictureInPictureAutomaticallyFromInline = true
        options.preferredForwardBufferDuration = media.isLive ? 4 : 8
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
        currentTime: .constant(0),
        duration: .constant(120)
    )
    .preferredColorScheme(.dark)
}

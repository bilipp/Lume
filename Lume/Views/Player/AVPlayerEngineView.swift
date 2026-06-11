import AVFoundation
import SwiftData
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// AVPlayer-backed video host with custom Apple-style controls.
///
/// This used to wrap `AVPlayerViewController` and lean on AVKit's built-in
/// transport. To match the VLCKit and KSPlayer engines — which both draw their
/// own auto-hiding overlay — it now renders straight into an `AVPlayerLayer`
/// (`AVPlayerVideoContainer`) and layers the very same controls on top: the
/// shared `TVPlayerControlsOverlay` on tvOS, and `AVPlayerControlsOverlay` on
/// iOS / macOS. State (`AVPlayerCoordinator`), the tap-catcher, the auto-hide
/// timer and live-channel surfing all mirror `VLCPlayerEngineView`.
struct AVPlayerEngineView: View {
    let media: PlayableMedia
    /// High-frequency playback clock, held as the `@Observable` object rather
    /// than as `@Binding` scalars — see `VLCPlayerEngineView` for why this keeps
    /// the engine view off the per-tick re-render path.
    @Bindable var clock: PlaybackClock
    /// The episode queued after `media`, resolved by the host. Drives the
    /// end-of-episode Next Up affordances; `nil` when there is nothing to play
    /// next.
    var nextUpMedia: PlayableMedia?
    /// Invoked when the viewer picks a different stream (another episode, or a
    /// live channel via the Siri remote) from the in-player overlay.
    var onSelectMedia: ((PlayableMedia) -> Void)?

    @StateObject private var coordinator = AVPlayerCoordinator()
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
    #if os(tvOS)
        /// The full channel browser (categories + channels) raised by a left
        /// press while watching live TV with the controls hidden.
        @State private var isChannelBrowserOpen = false
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
        ZStack {
            Color.black
                .ignoresSafeArea()

            AVPlayerVideoContainer(coordinator: coordinator)
                .ignoresSafeArea()

            // Always-present transparent layer that reliably catches taps over
            // the player surface, mirroring the VLCKit/KSPlayer hosts.
            tapCatcher

            if isControlsVisible {
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

            #if os(tvOS)
                if isChannelBrowserOpen {
                    channelBrowser
                }
            #endif
        }
        .preferredColorScheme(.dark)
        .onAppear {
            coordinator.onTime = { current in
                if !isSeeking, current.isFinite { clock.current = current }
            }
            coordinator.onDuration = { total in
                if total.isFinite, total > 0 { clock.duration = total }
            }
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
            coordinator.reload(media: newMedia)
            resetHideTimer()
        }
        .onChange(of: isControlsVisible) { _, visible in
            #if os(tvOS)
                if !visible { Task { @MainActor in catcherFocused = true } }
            #endif
        }
        .onMenuPress { handleMenuPress() }
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
            Button(action: showControls) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(AVInvisibleButtonStyle())
            .disabled(isControlsVisible || isChannelBrowserOpen)
            .focused($catcherFocused)
            .onMoveCommand { direction in
                // Left opens the channel browser; up/down surf adjacent
                // channels; right recalls the last channel watched.
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
            AVPlayerControlsOverlay(
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
        /// Change the live channel from the Siri Remote — up/down surf to the
        /// adjacent channel, right recalls the channel watched just before this
        /// one. Falls back to summoning the controls when there's nothing to
        /// jump to.
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
}

#if os(tvOS)
    /// Draws only its (clear) label so the full-screen tap-catcher stays
    /// invisible even while it holds focus with the controls hidden.
    private struct AVInvisibleButtonStyle: ButtonStyle {
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

// MARK: - Video Container (AVPlayerLayer bridge)

// Hosts a view whose backing layer is an `AVPlayerLayer`. The coordinator owns
// the `AVPlayer` and is handed the layer once it mounts so it can drive content
// gravity and Picture in Picture.
#if os(macOS)
    private struct AVPlayerVideoContainer: NSViewRepresentable {
        let coordinator: AVPlayerCoordinator

        func makeNSView(context _: Context) -> AVPlayerHostNSView {
            let view = AVPlayerHostNSView()
            coordinator.attach(layer: view.playerLayer)
            return view
        }

        func updateNSView(_: AVPlayerHostNSView, context _: Context) {}
    }

    /// AppKit has no `layerClass` hook, so the `AVPlayerLayer` is created and
    /// kept in sync with the view's bounds manually.
    private final class AVPlayerHostNSView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            playerLayer.frame = bounds
            layer?.addSublayer(playerLayer)
            layer?.backgroundColor = NSColor.black.cgColor
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
#else
    private struct AVPlayerVideoContainer: UIViewRepresentable {
        let coordinator: AVPlayerCoordinator

        func makeUIView(context _: Context) -> AVPlayerHostUIView {
            let view = AVPlayerHostUIView()
            view.backgroundColor = .black
            coordinator.attach(layer: view.playerLayer)
            return view
        }

        func updateUIView(_: AVPlayerHostUIView, context _: Context) {}
    }

    /// `layerClass` makes the view's backing layer an `AVPlayerLayer`, so it
    /// resizes with the view automatically.
    private final class AVPlayerHostUIView: UIView {
        // swiftlint:disable:next static_over_final_class
        override class var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            // swiftlint:disable:next force_cast
            layer as! AVPlayerLayer
        }
    }
#endif

#Preview {
    AVPlayerEngineView(
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

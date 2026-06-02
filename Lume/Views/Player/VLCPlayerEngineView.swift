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

    @StateObject private var coordinator = VLCPlayerCoordinator()
    @State private var isControlsVisible = true
    @State private var isSeeking = false
    @State private var seekPosition: TimeInterval = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var hoverHideTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss
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
            Color.clear
                .contentShape(Rectangle())
                .focusable(!isControlsVisible)
                .onMoveCommand { _ in showControls() }
                .onTapGesture { showControls() }
        #else
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
        #endif
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
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
    }

    // MARK: - Actions

    private func togglePlay() {
        coordinator.togglePlay()
        resetHideTimer()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible.toggle() }
        if isControlsVisible { scheduleHide() }
    }

    private func showControls() {
        guard !isControlsVisible else { resetHideTimer(); return }
        withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = true }
        scheduleHide()
    }

    private func resetHideTimer() {
        hideTask?.cancel()
        if isControlsVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard coordinator.isPlaying else { return }
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

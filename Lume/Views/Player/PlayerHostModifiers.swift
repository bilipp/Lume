//
//  PlayerHostModifiers.swift
//  Lume
//
//  Chrome every engine host shares: the tvOS tap-catcher's button style, the
//  Siri Remote's Menu and Play/Pause presses, the macOS hover reveal, and the
//  playback-rate label.
//

import SwiftUI

#if os(tvOS)
    /// Draws only its (clear) label — no focus highlight, scale or background —
    /// so the full-screen tap-catcher stays invisible even while it holds focus
    /// with the controls hidden.
    struct PlayerInvisibleButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
        }
    }
#endif

extension View {
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

#if os(macOS)
    extension View {
        /// Shows the controls while the pointer moves over the player and
        /// hides them `hideDelay` after it leaves.
        func playerHoverRevealsControls(
            _ isControlsVisible: Binding<Bool>,
            hideDelay: Duration = .milliseconds(600),
            onActivity: @escaping () -> Void
        ) -> some View {
            modifier(PlayerHoverRevealModifier(
                isControlsVisible: isControlsVisible,
                hideDelay: hideDelay,
                onActivity: onActivity
            ))
        }
    }

    private struct PlayerHoverRevealModifier: ViewModifier {
        @Binding var isControlsVisible: Bool
        let hideDelay: Duration
        var onActivity: () -> Void
        @State private var hoverHideTask: Task<Void, Never>?

        func body(content: Content) -> some View {
            content
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active:
                        if !isControlsVisible {
                            withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = true }
                        }
                        onActivity()
                        hoverHideTask?.cancel()
                    case .ended:
                        hoverHideTask?.cancel()
                        let hideDelay = hideDelay
                        hoverHideTask = Task { @MainActor in
                            try? await Task.sleep(for: hideDelay)
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = false }
                        }
                    }
                }
                .onDisappear { hoverHideTask?.cancel() }
        }
    }
#endif

extension Float {
    /// Compact playback-rate label, e.g. `1×`, `1.25×`. `%g` drops trailing zeros.
    nonisolated var playbackRateLabel: String {
        String(format: "%g×", self)
    }
}

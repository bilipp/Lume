import SwiftUI

/// An engine coordinator the macOS player's `PlayerVolumeStore` drives.
protocol PlayerVolumeApplying: AnyObject {
    /// True while another device owns the volume (AirPlay); the volume control
    /// and its keys stand down then, so they never change the stored level.
    var isVolumeRoutedExternally: Bool { get }

    func applyUserVolume(level: Float, muted: Bool)
}

extension PlayerVolumeApplying {
    var isVolumeRoutedExternally: Bool {
        false
    }
}

extension View {
    /// Owns the full-screen player's `PlayerVolumeStore` and injects it. Applied
    /// above the engine `.id`, so mute survives engine fallback but clears on
    /// close. macOS only.
    @ViewBuilder
    func playerVolumeSession() -> some View {
        #if os(macOS)
            modifier(PlayerVolumeSession())
        #else
            self
        #endif
    }
}

#if os(macOS)
    private struct PlayerVolumeSession: ViewModifier {
        @State private var playerVolume = PlayerVolumeStore()

        func body(content: Content) -> some View {
            content.environment(playerVolume)
        }
    }

    extension View {
        /// Pushes the full-screen player's `PlayerVolumeStore` into an engine on
        /// appear and whenever its level or mute changes. The volume keys live
        /// in `playerKeyboardShortcuts`. Without a store in the environment
        /// (Multi-View tiles, previews) it does nothing. Engine fallback
        /// rebuilds the engine view, whose appear re-applies the surviving
        /// store.
        func playerVolume(_ engine: some PlayerVolumeApplying) -> some View {
            modifier(PlayerVolumeEngineLink(
                apply: engine.applyUserVolume,
                isRoutedExternally: engine.isVolumeRoutedExternally
            ))
        }
    }

    /// Reads the store in its own body, so a slider drag re-evaluates this
    /// modifier rather than the whole engine view.
    private struct PlayerVolumeEngineLink: ViewModifier {
        let apply: (Float, Bool) -> Void
        let isRoutedExternally: Bool

        @Environment(PlayerVolumeStore.self) private var playerVolume: PlayerVolumeStore?

        func body(content: Content) -> some View {
            content
                .onAppear { push() }
                .onChange(of: playerVolume?.level) { _, _ in push() }
                .onChange(of: playerVolume?.isMuted) { _, _ in push() }
                .onChange(of: isRoutedExternally, initial: true) { _, routed in
                    playerVolume?.isRoutedExternally = routed
                }
        }

        private func push() {
            guard let playerVolume else { return }
            apply(playerVolume.level, playerVolume.isMuted)
        }
    }
#endif

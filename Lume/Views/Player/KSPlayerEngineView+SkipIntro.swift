import SwiftUI

/// The Skip Intro affordance for the KSPlayer host, kept out of the main file
/// (which is at its length cap) and shared by both the tvOS and iOS/macOS
/// bodies. `controlsVisible` and the seek action are passed in because each body
/// owns them differently — the tvOS body also restores remote focus after a
/// skip, the iOS/macOS body seeks straight through the coordinator.
@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
extension KSPlayerEngineView {
    @ViewBuilder
    func skipIntroOverlay(
        controlsVisible: Bool,
        onSeek: @escaping (TimeInterval) -> Void
    ) -> some View {
        if let skipSegments {
            PlayerSkipIntroOverlay(
                segments: skipSegments,
                clock: clock,
                controlsVisible: controlsVisible,
                onSeek: onSeek
            )
        }
    }
}

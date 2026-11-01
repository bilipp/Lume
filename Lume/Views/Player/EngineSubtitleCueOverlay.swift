import SwiftUI

/// Draws an engine's active subtitle cues over the video, for the hosts that
/// render cues themselves (LumeEngine, AetherEngine). A leaf that observes only
/// the standalone `SubtitleCueModel`, so per-cue changes invalidate this view
/// alone — never the engine view above it, and never the controls overlay
/// (both of which observe the coordinator, whose `objectWillChange` therefore
/// no longer fires at tick rate). Keeping the cue text off the coordinator is
/// what stops an open track menu flickering and dropping taps.
struct EngineSubtitleCueOverlay: View {
    @ObservedObject var cues: SubtitleCueModel
    /// Lifts the cues above the controls' scrubber while they're showing.
    let controlsVisible: Bool
    @AppStorage(SubtitleStyle.storageKey) private var style = SubtitleStyle.default

    var body: some View {
        if let text = cues.text, !text.isEmpty {
            VStack {
                Spacer()
                Text(text)
                    .multilineTextAlignment(.center)
                    .subtitleStyle(style)
                    .padding(.horizontal)
                    .padding(.bottom, controlsVisible ? 120 : 40)
            }
            .subtitleLift(style.position)
            .allowsHitTesting(false)
        }
    }
}

import SwiftUI

/// Draws the engine's active subtitle cues over the video. A leaf that observes
/// only the standalone `SubtitleCueModel`, so per-cue changes invalidate this
/// view alone — never the engine view above it, and never the controls overlay
/// (both of which observe the coordinator, whose `objectWillChange` therefore
/// no longer fires at tick rate). Keeping the cue text off the coordinator is
/// what stops an open track menu flickering and dropping taps.
struct LumeEngineSubtitleOverlay: View {
    @ObservedObject var cues: SubtitleCueModel
    /// Lifts the cues above the controls' scrubber while they're showing.
    let controlsVisible: Bool

    var body: some View {
        if let text = cues.text, !text.isEmpty {
            VStack {
                Spacer()
                Text(text)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, controlsVisible ? 120 : 40)
            }
            .allowsHitTesting(false)
        }
    }
}

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
    /// The picture's pixel size, which places bitmap cues on the video rect;
    /// nil spreads them over the whole surface.
    var videoSize: CGSize?
    @AppStorage(SubtitleStyle.storageKey) private var style = SubtitleStyle.default

    var body: some View {
        ZStack {
            textCue
            if !cues.bitmaps.isEmpty {
                bitmapCues
            }
        }
    }

    /// Bitmap cues (PGS, DVB, DVD) drawn where the disc placed them, laid out
    /// over the full surface because the video ignores the safe area too.
    private var bitmapCues: some View {
        GeometryReader { proxy in
            ForEach(cues.bitmaps) { cue in
                let frame = SubtitleBitmap.frame(
                    position: cue.position,
                    canvasSize: cue.canvasSize,
                    videoSize: videoSize,
                    in: proxy.size
                )
                Image(decorative: cue.image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .offset(y: controlsVisible && frame.midY > proxy.size.height / 2 ? -80 : 0)
            }
        }
        .ignoresSafeArea()
        .subtitleLift(style.position)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var textCue: some View {
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

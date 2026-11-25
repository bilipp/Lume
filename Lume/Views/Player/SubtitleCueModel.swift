import Combine
import CoreGraphics
import Foundation

/// Holds the engine's active subtitle cues, refreshed from the coordinator's
/// 10 Hz playback tick. Deliberately a separate `ObservableObject` from
/// `LumeEngineCoordinator`: were the cue text `@Published` on the coordinator,
/// every per-tick update would fire the coordinator's `objectWillChange` and
/// re-render every overlay that observes it — flickering an open audio/subtitle
/// `Menu` and cancelling in-flight taps. Only the subtitle-rendering leaf
/// observes this model, so a cue change invalidates that leaf alone. Mirrors why
/// KSPlayer keeps its `SubtitleModel` off the controls overlay's observed surface.
@MainActor
final class SubtitleCueModel: ObservableObject {
    @Published private(set) var text: String?
    /// Bitmap cues (PGS, DVB, DVD) showing now and drawn as pictures; only
    /// AetherEngine sends them.
    @Published private(set) var bitmaps: [SubtitleBitmap] = []

    /// The engine's text cues, and the bitmap cues that are shown as text.
    private var cueText: String?
    private var bitmapText: String?

    /// Assigns only on an actual change, so an unchanged cue repeated across
    /// ticks doesn't invalidate the leaf ten times a second.
    func update(_ newText: String?) {
        cueText = newText
        publishText()
    }

    /// Bitmap cues whose text was read reliably join the text cue and are
    /// not drawn; the rest stay pictures.
    func updateBitmaps(_ newBitmaps: [SubtitleBitmap]) {
        let readable = SubtitleBitmap.readableText(of: newBitmaps)
        let drawn = readable == nil ? newBitmaps : []
        if bitmaps != drawn {
            bitmaps = drawn
        }
        bitmapText = readable
        publishText()
    }

    private func publishText() {
        let lines = [cueText, bitmapText].compactMap(\.self).filter { !$0.isEmpty }
        let newText = lines.isEmpty ? nil : lines.joined(separator: "\n")
        if text != newText {
            text = newText
        }
    }

    /// Clears every cue: a new load, subtitles off.
    func clear() {
        update(nil)
        updateBitmaps([])
    }
}

/// A rendered bitmap subtitle cue. `position` is normalized to [0, 1] against
/// the subtitle canvas, `canvasSize` that canvas in pixels (`.zero` when the
/// source named none, so the canvas is the video frame).
nonisolated struct SubtitleBitmap: Identifiable, Equatable, @unchecked Sendable {
    let id: Int
    let image: CGImage
    let position: CGRect
    let canvasSize: CGSize
    /// What on-device text recognition read in the picture, with the lowest
    /// confidence among its lines. Nil until the engine has read the cue, and
    /// always when the engine wasn't asked to (`AetherEngineOptions.bitmapSubtitleText`).
    var recognizedText: String?
    var recognizedTextConfidence: Float?

    /// Cue identity, never the pixels: a cue's image doesn't change.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.position == rhs.position && lhs.canvasSize == rhs.canvasSize
            && lhs.recognizedText == rhs.recognizedText
            && lhs.recognizedTextConfidence == rhs.recognizedTextConfidence
    }

    /// Below this a cue keeps its picture. The recognizer answers a few fixed
    /// grades (0.3, 0.5 and 1.0 are common), so this passes the upper two.
    static let minimumTextConfidence: Float = 0.5

    /// The cues as one caption, top cue first, or nil when any of them has
    /// to stay a picture: text for one cue next to the picture of another
    /// would put two styles on screen, and could put one on top of the other.
    static func readableText(of bitmaps: [SubtitleBitmap]) -> String? {
        guard !bitmaps.isEmpty else { return nil }
        var lines: [String] = []
        for bitmap in bitmaps.sorted(by: { $0.position.minY < $1.position.minY }) {
            guard let text = bitmap.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let confidence = bitmap.recognizedTextConfidence, confidence >= minimumTextConfidence
            else { return nil }
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    /// Where the cue lands in a container of `container` points showing a
    /// `videoSize` picture aspect-fit. The canvas maps width-aligned and
    /// centred onto the video rect, so a canvas taller than a cropped video
    /// keeps its cues where the disc authored them, the lower bar included.
    /// Without a video size the container stands in for the video.
    static func frame(position: CGRect, canvasSize: CGSize, videoSize: CGSize?, in container: CGSize) -> CGRect {
        let video = videoRect(videoSize, in: container)
        var canvas = video
        if canvasSize.width > 0, canvasSize.height > 0 {
            let height = video.width * canvasSize.height / canvasSize.width
            canvas = CGRect(x: video.minX, y: video.midY - height / 2, width: video.width, height: height)
        }
        return CGRect(
            x: canvas.minX + position.minX * canvas.width,
            y: canvas.minY + position.minY * canvas.height,
            width: position.width * canvas.width,
            height: position.height * canvas.height
        )
    }

    private static func videoRect(_ videoSize: CGSize?, in container: CGSize) -> CGRect {
        guard let videoSize, videoSize.width > 0, videoSize.height > 0,
              container.width > 0, container.height > 0
        else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / videoSize.width, container.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

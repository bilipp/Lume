import Combine
import CoreGraphics
@testable import Lume
import Testing

struct SubtitleBitmapLayoutTests {
    private let screen = CGSize(width: 1920, height: 1080)

    @Test func `a cue on a canvas the size of the video lands where the disc put it`() {
        let frame = SubtitleBitmap.frame(
            position: CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.125),
            canvasSize: CGSize(width: 1920, height: 1080),
            videoSize: CGSize(width: 1920, height: 1080),
            in: screen
        )
        #expect(frame == CGRect(x: 480, y: 810, width: 960, height: 135))
    }

    @Test func `no canvas means the video frame`() {
        let frame = SubtitleBitmap.frame(
            position: CGRect(x: 0, y: 0, width: 1, height: 1),
            canvasSize: .zero,
            videoSize: CGSize(width: 1920, height: 800),
            in: screen
        )
        #expect(frame == CGRect(x: 0, y: 140, width: 1920, height: 800))
    }

    @Test func `a 16 by 9 canvas over a cropped scope video keeps its lower cues below the picture`() {
        // A 2.40:1 encode of a disc whose PGS canvas is 1920x1080.
        let frame = SubtitleBitmap.frame(
            position: CGRect(x: 0.25, y: 0.875, width: 0.5, height: 0.0625),
            canvasSize: CGSize(width: 1920, height: 1080),
            videoSize: CGSize(width: 1920, height: 800),
            in: screen
        )
        #expect(frame == CGRect(x: 480, y: 945, width: 960, height: 67.5))
    }

    @Test func `a pillarboxed video scales the canvas to its width`() {
        let frame = SubtitleBitmap.frame(
            position: CGRect(x: 0, y: 0.5, width: 1, height: 0.5),
            canvasSize: CGSize(width: 720, height: 576),
            videoSize: CGSize(width: 720, height: 576),
            in: screen
        )
        // 720x576 fits 1350x1080, centred.
        #expect(frame == CGRect(x: 285, y: 540, width: 1350, height: 540))
    }

    @Test func `without a video size the container stands in`() {
        let frame = SubtitleBitmap.frame(
            position: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            canvasSize: .zero,
            videoSize: nil,
            in: CGSize(width: 1000, height: 500)
        )
        #expect(frame == CGRect(x: 500, y: 250, width: 500, height: 250))
    }

    @Test @MainActor func `the cue model only republishes a changed set`() throws {
        let model = SubtitleCueModel()
        let image = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        let cue = SubtitleBitmap(id: 1, image: image, position: .zero, canvasSize: .zero)
        var changes = 0
        let token = model.objectWillChange.sink { changes += 1 }
        model.updateBitmaps([cue])
        model.updateBitmaps([cue])
        model.clear()
        model.clear()
        token.cancel()
        #expect(changes == 2)
        #expect(model.bitmaps.isEmpty)
    }

    private func cue(
        id: Int, top: CGFloat = 0.8, text: String? = nil, confidence: Float? = nil
    ) throws -> SubtitleBitmap {
        let image = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        return SubtitleBitmap(
            id: id, image: image,
            position: CGRect(x: 0.25, y: top, width: 0.5, height: 0.1), canvasSize: .zero,
            recognizedText: text, recognizedTextConfidence: confidence
        )
    }

    @Test func `cues read with confidence become one caption, top cue first`() throws {
        let lower = try cue(id: 1, top: 0.85, text: "- No.", confidence: 0.5)
        let upper = try cue(id: 2, top: 0.75, text: " - Yes. ", confidence: 1)
        #expect(SubtitleBitmap.readableText(of: [lower, upper]) == "- Yes.\n- No.")
    }

    @Test func `an unread, empty or unsure cue keeps every cue a picture`() throws {
        let sure = try cue(id: 1, text: "Hello", confidence: 1)
        #expect(SubtitleBitmap.readableText(of: []) == nil)
        #expect(try SubtitleBitmap.readableText(of: [sure, cue(id: 2)]) == nil)
        #expect(try SubtitleBitmap.readableText(of: [sure, cue(id: 2, text: "  ", confidence: 1)]) == nil)
        #expect(try SubtitleBitmap.readableText(of: [sure, cue(id: 2, text: "He1lo", confidence: 0.3)]) == nil)
    }

    @Test @MainActor func `the cue model swaps the picture for text once the cue is read`() throws {
        let model = SubtitleCueModel()
        try model.updateBitmaps([cue(id: 1)])
        #expect(model.bitmaps.count == 1)
        #expect(model.text == nil)

        try model.updateBitmaps([cue(id: 1, text: "Hello", confidence: 1)])
        #expect(model.bitmaps.isEmpty)
        #expect(model.text == "Hello")

        model.update("Sign")
        #expect(model.text == "Sign\nHello")

        model.updateBitmaps([])
        #expect(model.text == "Sign")
        model.clear()
        #expect(model.text == nil)
    }
}

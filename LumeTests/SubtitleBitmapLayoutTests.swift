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
}

import CoreGraphics
import Foundation
@testable import Lume
import Testing

struct EPGStickyTextTests {
    @Test func `a fully visible block does not shift its text`() {
        #expect(EPGStickyText.shift(blockMinX: 0, blockWidth: 180, inset: 10) == 0)
        #expect(EPGStickyText.shift(blockMinX: 240, blockWidth: 180, inset: 10) == 0)
    }

    @Test func `a block scrolled past the leading edge shifts by the hidden amount`() {
        #expect(EPGStickyText.shift(blockMinX: -40, blockWidth: 180, inset: 10) == 40)
    }

    @Test func `the shift is capped inside the block`() {
        // 180 wide, 10 inset either side -> the text never travels past 160.
        #expect(EPGStickyText.shift(blockMinX: -400, blockWidth: 180, inset: 10) == 160)
    }

    @Test func `a block narrower than its own insets never shifts`() {
        #expect(EPGStickyText.shift(blockMinX: -40, blockWidth: 12, inset: 10) == 0)
    }
}

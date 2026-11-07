//
//  HueFrameGridLinearTests.swift
//  LumeTests
//

@testable import Lume
import Testing

struct HueFrameGridLinearTests {
    @Test func `reference white and black encode to the byte ends`() {
        #expect(HueFrameGrid.encode(1) == 255)
        #expect(HueFrameGrid.encode(0) == 0)
    }

    @Test func `mid grey follows the sRGB curve`() {
        // 18 % grey is sRGB ≈ 0.4613.
        #expect(HueFrameGrid.encode(0.18) == 118)
        // The linear segment below the knee.
        #expect(HueFrameGrid.encode(0.002) == 7)
    }

    @Test(arguments: [-0.5, .nan, -.infinity] as [Float])
    func `negative and invalid values encode as black`(value: Float) {
        #expect(HueFrameGrid.encode(value) == 0)
    }

    @Test func `values above reference white clip`() {
        #expect(HueFrameGrid.encode(2) == 255)
    }

    @Test func `grid keeps row major order`() throws {
        let colors: [HueFrameGrid.LinearColor] = [
            .init(red: 1, green: 0, blue: 0),
            .init(red: 0, green: 1, blue: 0),
            .init(red: 0, green: 0, blue: 1),
            .init(red: 1, green: 1, blue: 1)
        ]
        let grid = try #require(HueFrameGrid(width: 2, height: 2, linear: colors))
        #expect(grid.rgb == [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
        #expect(grid.color(column: 1, row: 0) == HueRGB(red: 0, green: 1, blue: 0))
    }

    @Test func `mismatched count is rejected`() {
        let colors = [HueFrameGrid.LinearColor(red: 0, green: 0, blue: 0)]
        #expect(HueFrameGrid(width: 2, height: 1, linear: colors) == nil)
    }
}

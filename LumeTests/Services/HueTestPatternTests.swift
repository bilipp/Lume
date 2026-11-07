//
//  HueTestPatternTests.swift
//  LumeTests
//

@testable import Lume
import Testing

struct HueTestPatternTests {
    @Test func `runs red, green, blue, white and holds the last colour`() {
        let step = HueTestPattern.stepDuration
        #expect(HueTestPattern.color(at: .zero) == .init(red: 1, green: 0, blue: 0))
        #expect(HueTestPattern.color(at: step) == .init(red: 0, green: 1, blue: 0))
        #expect(HueTestPattern.color(at: step * 2 + .milliseconds(10)) == .init(red: 0, green: 0, blue: 1))
        #expect(HueTestPattern.color(at: step * 3) == .init(red: 1, green: 1, blue: 1))
        #expect(HueTestPattern.color(at: HueTestPattern.duration * 2) == .init(red: 1, green: 1, blue: 1))
        #expect(HueTestPattern.duration == step * 4)
    }

    @Test func `fills the whole standard grid with one colour`() throws {
        let grid = try #require(HueTestPattern.grid(at: HueTestPattern.stepDuration))
        #expect(grid.width == HueFrameGrid.standardWidth)
        #expect(grid.height == HueFrameGrid.standardHeight)
        let whole = HueFrameGrid.Rect(columns: 0 ..< grid.width, rows: 0 ..< grid.height)
        #expect(grid.average(of: whole) == HueRGB(red: 0, green: 1, blue: 0))
    }

    @Test func `the source always hands out a grid`() {
        let source = HueTestPatternSource()
        guard case let .frame(.grid(grid)) = source.latestFrame() else {
            Issue.record("expected a grid frame")
            return
        }
        #expect(grid.color(column: 0, row: 0) == HueRGB(red: 1, green: 0, blue: 0))
        #expect(source.unavailableReason == nil)
    }
}

//
//  HueChannelLayoutTests.swift
//  LumeTests
//
//  Region mapping against the real `TV` area's channel positions (see
//  `LumeTests/Fixtures/Hue/README.md`).
//

import Foundation
@testable import Lume
import Testing

struct HueChannelLayoutTests {
    private static let width = HueFrameGrid.standardWidth
    private static let height = HueFrameGrid.standardHeight

    private static let tvArea = HueChannelLayout(channels: [
        HueEntertainmentChannel(channelID: 0, position: .init(x: 0.47, y: 1.0, z: -1.0), members: []),
        HueEntertainmentChannel(channelID: 1, position: .init(x: -0.11, y: 0.04, z: 1.0), members: [])
    ])

    private static let red: [UInt8] = [255, 0, 0]
    private static let green: [UInt8] = [0, 255, 0]
    private static let blue: [UInt8] = [0, 0, 255]
    private static let black: [UInt8] = [0, 0, 0]

    private static func grid(_ pixel: (_ column: Int, _ row: Int) -> [UInt8]) throws -> HueFrameGrid {
        var bytes = [UInt8]()
        for row in 0 ..< height {
            for column in 0 ..< width {
                bytes += pixel(column, row)
            }
        }
        return try #require(HueFrameGrid(width: width, height: height, rgb: bytes))
    }

    @Test func `TV channels map to bottom-right and top-centre`() {
        let placements = Self.tvArea.placements
        #expect(placements.map(\.channelID) == [0, 1])
        #expect(abs(placements[0].horizontal - 0.735) < 1e-9)
        #expect(placements[0].vertical == 1)
        #expect(abs(placements[1].horizontal - 0.445) < 1e-9)
        #expect(placements[1].vertical == 0)

        let full = HueFrameGrid.Rect(columns: 0 ..< Self.width, rows: 0 ..< Self.height)
        #expect(Self.tvArea.region(for: placements[0], in: full) == .init(columns: 17 ..< 30, rows: 9 ..< 18))
        #expect(Self.tvArea.region(for: placements[1], in: full) == .init(columns: 8 ..< 21, rows: 0 ..< 9))
    }

    @Test func `TV channels take the colour of their half of the picture`() throws {
        let frame = try Self.grid { _, row in row < Self.height / 2 ? Self.blue : Self.red }
        let samples = Self.tvArea.samples(from: frame)
        #expect(samples == [HueRGB(red: 1, green: 0, blue: 0), HueRGB(red: 0, green: 0, blue: 1)])
    }

    @Test func `letterbox bars are skipped`() throws {
        let frame = try Self.grid { _, row in
            switch row {
            case 0 ..< 3, 15 ..< 18: Self.black
            case 3 ..< 9: Self.green
            default: Self.red
            }
        }
        #expect(HueChannelLayout.activePicture(in: frame) == .init(columns: 0 ..< Self.width, rows: 3 ..< 15))
        let samples = Self.tvArea.samples(from: frame)
        #expect(samples == [HueRGB(red: 1, green: 0, blue: 0), HueRGB(red: 0, green: 1, blue: 0)])
    }

    @Test func `pillarbox bars are skipped`() throws {
        let frame = try Self.grid { column, _ in (4 ..< 28).contains(column) ? Self.green : Self.black }
        #expect(HueChannelLayout.activePicture(in: frame) == .init(columns: 4 ..< 28, rows: 0 ..< Self.height))
        let samples = Self.tvArea.samples(from: frame)
        #expect(samples.allSatisfy { $0 == HueRGB(red: 0, green: 1, blue: 0) })
    }

    @Test func `a dark band on one side only isn't a bar`() throws {
        let frame = try Self.grid { _, row in row < 4 ? Self.black : Self.red }
        #expect(HueChannelLayout.activePicture(in: frame) == frame.full)
    }

    @Test func `bars never take more than the cap`() throws {
        let frame = try Self.grid { _, row in (8 ..< 10).contains(row) ? Self.red : Self.black }
        let cap = Int(Double(Self.height) * HueChannelLayout.maximumBarFraction)
        #expect(HueChannelLayout.activePicture(in: frame).rows == cap ..< Self.height - cap)
    }

    @Test func `an all-black frame keeps the whole picture`() throws {
        let frame = try Self.grid { _, _ in Self.black }
        #expect(HueChannelLayout.activePicture(in: frame) == frame.full)
        #expect(Self.tvArea.samples(from: frame).allSatisfy { $0 == .black })
    }

    @Test func `a region averages its pixels`() throws {
        let frame = try Self.grid { column, _ in column.isMultiple(of: 2) ? [255, 255, 255] : Self.black }
        let average = frame.average(of: .init(columns: 0 ..< 4, rows: 0 ..< 2))
        #expect(average == HueRGB(red: 0.5, green: 0.5, blue: 0.5))
    }

    @Test func `a grid needs exactly three bytes per pixel`() {
        #expect(HueFrameGrid(width: 2, height: 2, rgb: Array(repeating: 0, count: 11)) == nil)
        #expect(HueFrameGrid(width: 0, height: 2, rgb: []) == nil)
        #expect(HueFrameGrid(width: 2, height: 2, rgb: Array(repeating: 0, count: 12)) != nil)
    }

    @Test func `positions outside the area clamp to the picture edge`() {
        let layout = HueChannelLayout(channels: [
            HueEntertainmentChannel(channelID: 3, position: .init(x: 4, y: 0, z: -9), members: []),
            HueEntertainmentChannel(channelID: 300, position: .init(x: 0, y: 0, z: 0), members: [])
        ])
        #expect(layout.placements == [.init(channelID: 3, horizontal: 1, vertical: 1)])
    }
}

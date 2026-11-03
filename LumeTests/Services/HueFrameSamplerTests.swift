//
//  HueFrameSamplerTests.swift
//  LumeTests
//

import CoreVideo
import Foundation
@testable import Lume
import Testing

struct HueFrameSamplerTests {
    private static let areaID = "8d199a37-5ce4-4aae-a60e-db5d0aa27df3"
    /// The real 'TV' area: channel 0 bottom right, channel 1 top centre.
    private static let tvLayout = HueChannelLayout(channels: [
        HueEntertainmentChannel(channelID: 0, position: .init(x: 0.47, y: 1.0, z: -1.0), members: []),
        HueEntertainmentChannel(channelID: 1, position: .init(x: -0.11, y: 0.04, z: 1.0), members: [])
    ])

    // MARK: - Downscaling

    @Test func `bgra frame scales to its colour`() throws {
        let buffer = try Self.bgraBuffer(width: 64, height: 36) { _, _ in (red: 200, green: 40, blue: 90) }
        let grid = try #require(HueFrameDownscaler().grid(from: buffer))

        #expect(grid.width == HueFrameGrid.standardWidth)
        #expect(grid.height == HueFrameGrid.standardHeight)
        Self.expect(grid.color(column: 5, row: 5), near: (200, 40, 90))
        Self.expect(grid.color(column: 31, row: 17), near: (200, 40, 90))
    }

    @Test func `bgra frame keeps its halves apart`() throws {
        let buffer = try Self.bgraBuffer(width: 128, height: 72) { column, _ in
            column < 64 ? (red: 255, green: 0, blue: 0) : (red: 0, green: 0, blue: 255)
        }
        let grid = try #require(HueFrameDownscaler().grid(from: buffer))

        Self.expect(grid.color(column: 2, row: 9), near: (255, 0, 0))
        Self.expect(grid.color(column: 29, row: 9), near: (0, 0, 255))
    }

    @Test(arguments: [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    ])
    func `biplanar grey converts to grey`(format: OSType) throws {
        // Rec. 709 video range: Y 126 is a 50 % grey, chroma 128 is neutral.
        let buffer = try Self.biplanarBuffer(format: format, width: 64, height: 36, luma: 126, chroma: (128, 128))
        let grid = try #require(HueFrameDownscaler().grid(from: buffer))

        Self.expect(grid.color(column: 10, row: 10), near: (128, 128, 128))
    }

    @Test func `biplanar red converts to red`() throws {
        // Pure Rec. 709 red, video range: Y 63, Cb 102, Cr 240.
        let buffer = try Self.biplanarBuffer(
            format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: 64, height: 36, luma: 63, chroma: (102, 240)
        )
        let grid = try #require(HueFrameDownscaler().grid(from: buffer))

        Self.expect(grid.color(column: 16, row: 9), near: (255, 0, 0))
    }

    // MARK: - Packets

    @Test func `pixel buffer frame produces the area packet`() throws {
        var pipeline = try #require(Self.pipeline(intensity: .intense))
        let buffer = try Self.bgraBuffer(width: 64, height: 36) { _, _ in (red: 255, green: 255, blue: 255) }

        let produced = pipeline.packet(for: .frame(.pixelBuffer(buffer)), at: 0)
        let packet = try #require(produced)
        let bytes = [UInt8](packet)

        #expect(bytes.count == HueStreamMessage.headerLength + 2 * HueStreamMessage.channelLength)
        #expect(Array(bytes[0 ..< 9]) == Array("HueStream".utf8))
        #expect(bytes[11] == 0)
        #expect(String(bytes: bytes[16 ..< 52], encoding: .ascii) == Self.areaID)
        #expect(bytes[52] == 0)
        #expect(bytes[59] == 1)
        for offset in [53, 60] {
            let red = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            #expect(red > 0xF000)
        }
    }

    @Test func `grid frame passes through to the channels`() throws {
        // Top half blue, bottom half red: channel 1 sits on top, channel 0 below.
        let grid = try #require(Self.grid { _, row in row < 9 ? (0, 0, 255) : (255, 0, 0) })
        var pipeline = try #require(Self.pipeline(intensity: .intense))

        let produced = pipeline.packet(for: .frame(.grid(grid)), at: 0)
        let packet = try #require(produced)
        let channels = Self.channels(in: packet)

        #expect(channels[0].id == 0)
        #expect(channels[0].red > channels[0].blue)
        #expect(channels[1].id == 1)
        #expect(channels[1].blue > channels[1].red)
    }

    @Test func `missing frame repeats last colours with a new sequence`() throws {
        let grid = try #require(Self.grid { _, _ in (180, 60, 20) })
        var pipeline = try #require(Self.pipeline(intensity: .moderate))

        let firstPacket = pipeline.packet(for: .frame(.grid(grid)), at: 0)
        let first = try #require(firstPacket)
        let heldPacket = pipeline.packet(for: .noFrame, at: 0.02)
        let held = try #require(heldPacket)
        let unavailablePacket = pipeline.packet(for: .unavailable(.unsupportedContent), at: 0.04)
        let unavailable = try #require(unavailablePacket)

        #expect(held[11] == first[11] &+ 1)
        #expect(unavailable[11] == first[11] &+ 2)
        #expect(held.dropFirst(12) == first.dropFirst(12))
        #expect(unavailable.dropFirst(12) == first.dropFirst(12))
    }

    @Test func `no packet before the first frame`() throws {
        var pipeline = try #require(Self.pipeline(intensity: .high))
        let produced = pipeline.packet(for: .noFrame, at: 0)
        #expect(produced == nil)
    }

    @Test func `off intensity sends nothing`() throws {
        let grid = try #require(Self.grid { _, _ in (255, 255, 255) })
        var pipeline = try #require(Self.pipeline(intensity: .off))
        let produced = pipeline.packet(for: .frame(.grid(grid)), at: 0)
        #expect(produced == nil)
    }

    @Test func `intensity change reshapes held colours`() throws {
        let grid = try #require(Self.grid { _, _ in (255, 255, 255) })
        var pipeline = try #require(Self.pipeline(intensity: .intense))
        let brightPacket = pipeline.packet(for: .frame(.grid(grid)), at: 0)
        let bright = try #require(brightPacket)

        pipeline.setIntensity(.subtle)
        let dimPacket = pipeline.packet(for: .noFrame, at: 0.02)
        let dim = try #require(dimPacket)

        #expect(Self.channels(in: dim)[0].red < Self.channels(in: bright)[0].red)
    }

    @Test func `smoothing eases toward a new frame`() throws {
        let dark = try #require(Self.grid { _, _ in (100, 100, 100) })
        let lighter = try #require(Self.grid { _, _ in (110, 110, 110) })
        var pipeline = try #require(Self.pipeline(intensity: .subtle))

        _ = pipeline.packet(for: .frame(.grid(dark)), at: 0)
        let easedPacket = pipeline.packet(for: .frame(.grid(lighter)), at: 0.02)
        let eased = try #require(easedPacket)
        var reference = try #require(Self.pipeline(intensity: .subtle))
        let targetPacket = reference.packet(for: .frame(.grid(lighter)), at: 0)
        let target = try #require(targetPacket)
        var start = try #require(Self.pipeline(intensity: .subtle))
        let originPacket = start.packet(for: .frame(.grid(dark)), at: 0)
        let origin = try #require(originPacket)

        let value = Self.channels(in: eased)[0].red
        #expect(value > Self.channels(in: origin)[0].red)
        #expect(value < Self.channels(in: target)[0].red)
    }

    @Test func `invalid area id has no pipeline`() {
        #expect(HueFramePipeline(
            entertainmentConfigurationID: "nope", layout: Self.tvLayout, intensity: .high, reduceMotion: false
        ) == nil)
    }

    @Test func `sampler delivers off its queue`() async throws {
        let grid = try #require(Self.grid { _, _ in (0, 255, 0) })
        let sampler = try #require(HueFrameSampler(
            entertainmentConfigurationID: Self.areaID, layout: Self.tvLayout, intensity: .high, reduceMotion: false
        ))

        let packet = await withCheckedContinuation { continuation in
            sampler.submit(.frame(.grid(grid)), at: 0) { continuation.resume(returning: $0) }
        }
        #expect(Self.channels(in: packet)[0].green > 0xF000)
    }

    // MARK: - Helpers

    private typealias RGB = (red: UInt8, green: UInt8, blue: UInt8)

    private static func pipeline(intensity: HueIntensity) -> HueFramePipeline? {
        HueFramePipeline(
            entertainmentConfigurationID: areaID, layout: tvLayout, intensity: intensity, reduceMotion: false
        )
    }

    private static func grid(_ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> HueFrameGrid? {
        var rgb: [UInt8] = []
        for row in 0 ..< HueFrameGrid.standardHeight {
            for column in 0 ..< HueFrameGrid.standardWidth {
                let pixel = color(column, row)
                rgb += [pixel.0, pixel.1, pixel.2]
            }
        }
        return HueFrameGrid(width: HueFrameGrid.standardWidth, height: HueFrameGrid.standardHeight, rgb: rgb)
    }

    private static func channels(in packet: Data) -> [HueStreamMessage.Channel] {
        let bytes = [UInt8](packet)
        return stride(from: HueStreamMessage.headerLength, to: bytes.count, by: HueStreamMessage.channelLength).map {
            HueStreamMessage.Channel(
                id: bytes[$0],
                red: UInt16(bytes[$0 + 1]) << 8 | UInt16(bytes[$0 + 2]),
                green: UInt16(bytes[$0 + 3]) << 8 | UInt16(bytes[$0 + 4]),
                blue: UInt16(bytes[$0 + 5]) << 8 | UInt16(bytes[$0 + 6])
            )
        }
    }

    private static func expect(
        _ color: HueRGB,
        near expected: (Int, Int, Int),
        tolerance: Double = 12,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let actual = (color.red * 255, color.green * 255, color.blue * 255)
        #expect(abs(actual.0 - Double(expected.0)) <= tolerance, "red \(actual.0)", sourceLocation: sourceLocation)
        #expect(abs(actual.1 - Double(expected.1)) <= tolerance, "green \(actual.1)", sourceLocation: sourceLocation)
        #expect(abs(actual.2 - Double(expected.2)) <= tolerance, "blue \(actual.2)", sourceLocation: sourceLocation)
    }

    private static func tagRec709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate
        )
    }

    private static func bgraBuffer(width: Int, height: Int, color: (Int, Int) -> RGB) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &created)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let pixel = base + row * bytesPerRow + column * 4
                let value = color(column, row)
                pixel[0] = value.blue
                pixel[1] = value.green
                pixel[2] = value.red
                pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        tagRec709(buffer)
        return buffer
    }

    /// 8-bit samples; a 10-bit buffer stores them shifted into the high bits.
    private static func biplanarBuffer(
        format: OSType, width: Int, height: Int, luma: UInt8, chroma: (blue: UInt8, red: UInt8)
    ) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, nil, &created)
        let buffer = try #require(created)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0 ..< 2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let samples = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            for row in 0 ..< rows {
                let line = base + row * bytesPerRow
                for index in 0 ..< samples {
                    let value = plane == 0 ? luma : (index.isMultiple(of: 2) ? chroma.blue : chroma.red)
                    if tenBit {
                        line.assumingMemoryBound(to: UInt16.self)[index] = UInt16(value) << 8
                    } else {
                        line.assumingMemoryBound(to: UInt8.self)[index] = value
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        tagRec709(buffer)
        return buffer
    }
}

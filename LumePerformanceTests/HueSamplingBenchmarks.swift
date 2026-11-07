//
//  HueSamplingBenchmarks.swift
//  LumePerformanceTests
//
//  What one Hue light-sync tick costs on the sampler's queue: downscale a
//  decoded 1080p frame to the sampling grid, average the channel regions,
//  smooth, apply the intensity and encode the HueStream packet. The tick runs
//  ~50 times a second for as long as sync is on, beside a decoder that owns
//  the same CPU, so its per-tick cost is the number to watch.
//
//  Each measured block runs `ticks` ticks (10 s of playback) over a rotation
//  of `frameCount` distinct frames, so every tick downscales a new picture and
//  the smoother sees real changes; divide the clock by `ticks` for one tick.
//  The pipeline and its transfer session are built and warmed outside the
//  measured span, so the signpost metrics (one interval per name per
//  iteration, the first) read a warm tick.
//

import CoreVideo
import Foundation
@testable import Lume
import XCTest

final class HueSamplingBenchmarks: XCTestCase {
    private let ticks = 500
    private let frameCount = 8
    private let tickInterval = 0.02
    private static let areaID = "8d199a37-5ce4-4aae-a60e-db5d0aa27df3"
    /// The real 'TV' area: channel 0 bottom right, channel 1 top centre.
    private static let tvLayout = HueChannelLayout(channels: [
        HueEntertainmentChannel(channelID: 0, position: .init(x: 0.47, y: 1.0, z: -1.0), members: []),
        HueEntertainmentChannel(channelID: 1, position: .init(x: -0.11, y: 0.04, z: 1.0), members: [])
    ])

    /// KSPlayer's software path and AVPlayerItemVideoOutput taps asking for BGRA.
    func testTick1080pBGRA() throws {
        let frames = try PerfFixtures.hueFrames(.bgra, count: frameCount)
        measureTicks(frames.map { .pixelBuffer($0) })
    }

    /// The common hardware-decoded SDR shape: 8-bit 4:2:0, Rec. 709.
    func testTick1080p420v() throws {
        let frames = try PerfFixtures.hueFrames(.yuv420v, count: frameCount)
        measureTicks(frames.map { .pixelBuffer($0) })
    }

    /// HDR10: 10-bit 4:2:0 tagged BT.2020 / PQ, so the transfer also tone-maps
    /// into Rec. 709.
    func testTick1080pX420HDR() throws {
        let frames = try PerfFixtures.hueFrames(.yuv420x10PQ, count: frameCount)
        measureTicks(frames.map { .pixelBuffer($0) })
    }

    /// LumeEngine hands out a grid it already downscaled: map, smooth and
    /// encode only.
    func testTickPrescaledGrid() throws {
        let grids = try (0 ..< frameCount).map { index in
            try XCTUnwrap(PerfFixtures.hueGrid(seed: UInt64(index)))
        }
        measureTicks(grids.map { .grid($0) })
    }

    // MARK: - Harness

    private func measureTicks(_ frames: [HueFrame]) {
        let metrics: [XCTMetric] = [
            XCTClockMetric(),
            XCTCPUMetric(),
            M3UColdImportBenchmarks.signpostMetric(.hueDownscale),
            M3UColdImportBenchmarks.signpostMetric(.hueMap),
            M3UColdImportBenchmarks.signpostMetric(.hueEncode)
        ]
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: metrics, options: options) {
            guard var pipeline = HueFramePipeline(
                entertainmentConfigurationID: Self.areaID,
                layout: Self.tvLayout,
                intensity: .high,
                reduceMotion: false
            ) else {
                XCTFail("no pipeline for the TV area")
                return
            }
            _ = pipeline.packet(for: .frame(frames[frames.count - 1]), at: 0)

            var packets = 0
            startMeasuring()
            for tick in 1 ... ticks {
                let frame = frames[tick % frames.count]
                if pipeline.packet(for: .frame(frame), at: Double(tick) * tickInterval) != nil {
                    packets += 1
                }
            }
            stopMeasuring()
            XCTAssertEqual(packets, ticks, "a tick produced no packet; the benchmark measured a no-op")
        }
    }
}

// MARK: - Fixtures

extension PerfFixtures {
    enum HueFrameFormat {
        case bgra
        case yuv420v
        case yuv420x10PQ
    }

    private static let hueColumns = 16
    private static let hueRows = 9

    /// 1080p frames of 16 × 9 fixed-seed colour blocks, IOSurface-backed like a
    /// decoder's. Every second frame carries 2.39:1 letterbox bars, so the
    /// active-picture scan finds bars half the time.
    static func hueFrames(
        _ format: HueFrameFormat,
        count: Int,
        width: Int = 1920,
        height: Int = 1080
    ) throws -> [CVPixelBuffer] {
        var generator = SeededGenerator()
        return try (0 ..< count).map { index in
            let blocks = (0 ..< hueColumns * hueRows).map { _ in
                (
                    UInt8.random(in: 0 ... 255, using: &generator),
                    UInt8.random(in: 0 ... 255, using: &generator),
                    UInt8.random(in: 0 ... 255, using: &generator)
                )
            }
            let bar = index.isMultiple(of: 2) ? 0 : height * 140 / 1080
            let buffer = try makeHueBuffer(format, width: width, height: height)
            switch format {
            case .bgra:
                fillBGRA(buffer, blocks: blocks, bar: bar)
            case .yuv420v, .yuv420x10PQ:
                fillBiplanar(buffer, blocks: blocks, bar: bar, tenBit: format == .yuv420x10PQ)
            }
            tagHue(buffer, format)
            return buffer
        }
    }

    /// One standard-size sampling grid of the same block pattern.
    static func hueGrid(seed: UInt64) -> HueFrameGrid? {
        var generator = SeededGenerator(seed: 0x5EED_1234_ABCD_0001 &+ seed)
        let width = HueFrameGrid.standardWidth
        let height = HueFrameGrid.standardHeight
        let blocks = (0 ..< hueColumns * hueRows).map { _ in
            [
                UInt8.random(in: 0 ... 255, using: &generator),
                UInt8.random(in: 0 ... 255, using: &generator),
                UInt8.random(in: 0 ... 255, using: &generator)
            ]
        }
        var rgb: [UInt8] = []
        rgb.reserveCapacity(width * height * 3)
        for row in 0 ..< height {
            for column in 0 ..< width {
                rgb += blocks[(row * hueRows / height) * hueColumns + column * hueColumns / width]
            }
        }
        return HueFrameGrid(width: width, height: height, rgb: rgb)
    }

    private static func makeHueBuffer(_ format: HueFrameFormat, width: Int, height: Int) throws -> CVPixelBuffer {
        let pixelFormat = switch format {
        case .bgra: kCVPixelFormatType_32BGRA
        case .yuv420v: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .yuv420x10PQ: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, pixelFormat, attributes as CFDictionary, &created)
        return try XCTUnwrap(created)
    }

    private static func blockIndex(column: Int, row: Int, width: Int, height: Int) -> Int {
        (row * hueRows / height) * hueColumns + column * hueColumns / width
    }

    private static func fillBGRA(_ buffer: CVPixelBuffer, blocks: [(UInt8, UInt8, UInt8)], bar: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0 ..< height {
            let line = base + row * bytesPerRow
            let isBar = row < bar || row >= height - bar
            for column in 0 ..< width {
                let pixel = line + column * 4
                let color = isBar ? (0, 0, 0) : blocks[blockIndex(column: column, row: row, width: width, height: height)]
                pixel[0] = color.2
                pixel[1] = color.1
                pixel[2] = color.0
                pixel[3] = 255
            }
        }
    }

    /// Rec. 709 RGB → video-range Y'CbCr, written as 8-bit samples or as
    /// 10-bit samples in the high bits of each 16-bit word.
    private static func fillBiplanar(
        _ buffer: CVPixelBuffer,
        blocks: [(UInt8, UInt8, UInt8)],
        bar: Int,
        tenBit: Bool
    ) {
        let ycbcr = blocks.map { red, green, blue in
            let (redLevel, greenLevel, blueLevel) = (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
            let luma = 0.2126 * redLevel + 0.7152 * greenLevel + 0.0722 * blueLevel
            return (
                luma: 16 + 219 * luma,
                cb: 128 + 224 * (blueLevel - luma) / 1.8556,
                cr: 128 + 224 * (redLevel - luma) / 1.5748
            )
        }
        let black = (luma: 16.0, cb: 128.0, cr: 128.0)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0 ..< 2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let columns = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let scale = plane == 0 ? 1 : 2
            for row in 0 ..< rows {
                let line = base + row * bytesPerRow
                let pictureRow = row * scale
                let isBar = pictureRow < bar || pictureRow >= height - bar
                for column in 0 ..< columns {
                    let sample = isBar ? black : ycbcr[blockIndex(
                        column: column * scale, row: pictureRow, width: width, height: height
                    )]
                    if plane == 0 {
                        write(sample.luma, at: column, in: line, tenBit: tenBit)
                    } else {
                        write(sample.cb, at: column * 2, in: line, tenBit: tenBit)
                        write(sample.cr, at: column * 2 + 1, in: line, tenBit: tenBit)
                    }
                }
            }
        }
    }

    private static func write(_ value: Double, at index: Int, in line: UnsafeMutableRawPointer, tenBit: Bool) {
        if tenBit {
            line.assumingMemoryBound(to: UInt16.self)[index] = UInt16((value * 4).rounded()) << 6
        } else {
            line.assumingMemoryBound(to: UInt8.self)[index] = UInt8(value.rounded())
        }
    }

    private static func tagHue(_ buffer: CVPixelBuffer, _ format: HueFrameFormat) {
        let isPQ = format == .yuv420x10PQ
        let tags: [(CFString, CFString)] = [
            (kCVImageBufferColorPrimariesKey,
             isPQ ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey,
             isPQ ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey,
             isPQ ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        ]
        for (key, value) in tags {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
    }
}

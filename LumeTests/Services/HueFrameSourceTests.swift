//
//  HueFrameSourceTests.swift
//  LumeTests
//

import CoreVideo
@testable import Lume
import Testing

@MainActor
struct HueFrameSourceTests {
    private final class FakeFrameSource: HueFrameSource {
        var sample: HueFrameSample = .noFrame
        private(set) var detachCount = 0

        func latestFrame() -> HueFrameSample {
            sample
        }

        func detach() {
            detachCount += 1
        }
    }

    @Test func `dolby vision profile five is unsupported content`() {
        #expect(HueFrameUnavailableReason.forDolbyVisionProfile(5) == .unsupportedContent)
    }

    @Test(arguments: [nil, 4, 7, 8] as [UInt8?])
    func `other profiles stay available`(profile: UInt8?) {
        #expect(HueFrameUnavailableReason.forDolbyVisionProfile(profile) == nil)
    }

    @Test func `grid frame reaches caller unchanged`() throws {
        let grid = try #require(HueFrameGrid(width: 1, height: 1, rgb: [10, 20, 30]))
        let source = FakeFrameSource()
        source.sample = .frame(.grid(grid))
        let sample: any HueFrameSource = source

        guard case let .frame(.grid(received)) = sample.latestFrame() else {
            Issue.record("expected a grid frame")
            return
        }
        #expect(received == grid)
    }

    @Test func `pixel buffer frame keeps the engine buffer`() throws {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA, nil, &created)
        let buffer = try #require(created)
        let source = FakeFrameSource()
        source.sample = .frame(.pixelBuffer(buffer))

        guard case let .frame(.pixelBuffer(received)) = source.latestFrame() else {
            Issue.record("expected a pixel buffer frame")
            return
        }
        #expect(received === buffer)
    }

    @Test func `unavailable reason passes through`() {
        let source = FakeFrameSource()
        source.sample = .unavailable(.unsupportedEngine)

        guard case .unavailable(.unsupportedEngine) = source.latestFrame() else {
            Issue.record("expected unsupportedEngine")
            return
        }
        source.detach()
        #expect(source.detachCount == 1)
    }
}

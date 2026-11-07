//
//  HueColorSmootherTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import Testing

struct HueColorSmootherTests {
    private static func grey(_ value: Double) -> HueColorSmoother.Target {
        HueColorSmoother.Target(channels: [HueRGB(red: value, green: value, blue: value)], frameLuma: value)
    }

    private static func near(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 1e-9
    }

    @Test func `the first frame is shown as is`() {
        var smoother = HueColorSmoother(configuration: .init(timeConstant: 0.5))
        #expect(smoother.update(Self.grey(0.3), at: 10) == Self.grey(0.3).channels)
    }

    @Test func `small changes ease with the time constant`() throws {
        var smoother = HueColorSmoother(configuration: .init(timeConstant: 0.5))
        _ = smoother.update(Self.grey(0), at: 0)
        let eased = try #require(smoother.update(Self.grey(0.1), at: 0.5).first)
        #expect(Self.near(eased.red, 0.1 * (1 - exp(-1))))

        let later = try #require(smoother.update(Self.grey(0.1), at: 1.0).first)
        #expect(Self.near(later.red, 0.1 * (1 - exp(-2))))
    }

    @Test func `no time passing changes nothing`() throws {
        var smoother = HueColorSmoother(configuration: .init(timeConstant: 0.5))
        _ = smoother.update(Self.grey(0), at: 3)
        #expect(try #require(smoother.update(Self.grey(0.1), at: 3).first) == .black)
        #expect(try #require(smoother.update(Self.grey(0.1), at: 2).first) == .black)
    }

    @Test func `a luma jump is a cut and snaps`() {
        var smoother = HueColorSmoother(configuration: .init(timeConstant: 0.5))
        _ = smoother.update(Self.grey(0), at: 0)
        #expect(smoother.update(Self.grey(1), at: 0.02) == Self.grey(1).channels)
    }

    @Test func `a hue change at equal luma is a cut and snaps`() {
        var smoother = HueColorSmoother(configuration: .init(timeConstant: 0.5))
        let red = HueRGB(red: 1, green: 0, blue: 0)
        let cyan = HueRGB(red: 0, green: 0.6, blue: 0.6)
        _ = smoother.update(.init(channels: [red], frameLuma: 0.3), at: 0)
        #expect(smoother.update(.init(channels: [cyan], frameLuma: 0.3), at: 0.02) == [cyan])
    }

    @Test func `a slow fade is never a cut`() throws {
        var smoother = HueColorSmoother(configuration: .init(timeConstant: 0.5))
        _ = smoother.update(Self.grey(0), at: 0)
        var value = 0.0
        for step in 1 ... 20 {
            value = Double(step) * 0.05
            let output = try #require(smoother.update(Self.grey(value), at: Double(step) * 0.02).first)
            #expect(output.red < value)
        }
    }

    @Test func `reduce motion fades a cut at a capped rate`() throws {
        var configuration = HueColorSmoother.Configuration(timeConstant: 0.5)
        configuration.reduceMotion = true
        var smoother = HueColorSmoother(configuration: configuration)
        _ = smoother.update(Self.grey(0), at: 0)

        let first = try #require(smoother.update(Self.grey(1), at: 0.1).first)
        #expect(Self.near(first.red, configuration.reducedMotionMaximumRate * 0.1))

        let second = try #require(smoother.update(Self.grey(1), at: 0.2).first)
        #expect(Self.near(second.red, 0.5))

        let settled = try #require(smoother.update(Self.grey(1), at: 0.4).first)
        #expect(Self.near(settled.red, 0.5 + (1 - exp(-2)) * 0.5))
    }

    @Test func `reduce motion's fast fade ends after its window`() throws {
        var configuration = HueColorSmoother.Configuration(timeConstant: 0.5)
        configuration.reduceMotion = true
        configuration.reducedMotionMaximumRate = 100
        var smoother = HueColorSmoother(configuration: configuration)
        _ = smoother.update(Self.grey(0), at: 0)
        _ = smoother.update(Self.grey(0.8), at: 0.01)
        let fast = try #require(smoother.current.first).red

        _ = smoother.update(Self.grey(0.8), at: 1.0)
        let start = try #require(smoother.current.first).red
        let slow = try #require(smoother.update(Self.grey(0.8), at: 1.1).first).red
        #expect(Self.near(fast, 0.8 * (1 - exp(-0.1))))
        #expect(Self.near(slow, start + (0.8 - start) * (1 - exp(-0.2))))
    }

    @Test func `a changed channel count starts over`() {
        var smoother = HueColorSmoother(configuration: .init(timeConstant: 0.5))
        _ = smoother.update(Self.grey(0), at: 0)
        let two = HueColorSmoother.Target(channels: [.black, HueRGB(red: 0.05, green: 0, blue: 0)], frameLuma: 0)
        #expect(smoother.update(two, at: 0.02) == two.channels)
    }
}

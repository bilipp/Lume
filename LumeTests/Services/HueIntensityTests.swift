//
//  HueIntensityTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import Testing

struct HueIntensityTests {
    @Test func `raw values are the stored setting values`() {
        #expect(HueIntensity.allCases.map(\.rawValue) == ["off", "subtle", "moderate", "high", "intense"])
        #expect(HueIntensity(rawValue: "moderate") == .moderate)
    }

    @Test func `off streams nothing`() {
        #expect(HueIntensity.off.parameters == nil)
        #expect(HueIntensity.allCases.filter { $0 != .off }.allSatisfy { $0.parameters != nil })
    }

    @Test func `stronger levels are brighter, more saturated and faster`() throws {
        let levels = try [HueIntensity.subtle, .moderate, .high, .intense].map { try #require($0.parameters) }
        for (weaker, stronger) in zip(levels, levels.dropFirst()) {
            #expect(stronger.brightnessScale > weaker.brightnessScale)
            #expect(stronger.saturationBoost > weaker.saturationBoost)
            #expect(stronger.smoothingTimeConstant < weaker.smoothingTimeConstant)
            #expect(stronger.minimumBrightness <= weaker.minimumBrightness)
        }
        #expect(levels.allSatisfy { $0.minimumBrightness > 0 && $0.brightnessScale <= 1 })
    }

    @Test func `black lifts to the brightness floor`() throws {
        let parameters = try #require(HueIntensity.moderate.parameters)
        let floor = parameters.minimumBrightness
        #expect(parameters.apply(to: .black) == HueRGB(red: floor, green: floor, blue: floor))
    }

    @Test func `a dim colour lifts to the floor and keeps its hue`() throws {
        let parameters = try #require(HueIntensity.subtle.parameters)
        let result = parameters.apply(to: HueRGB(red: 0.02, green: 0.01, blue: 0))
        #expect(abs(result.maximumComponent - parameters.minimumBrightness) < 1e-9)
        #expect(result.red > result.green)
        #expect(result.green > result.blue)
    }

    @Test func `brightness scales white`() throws {
        let parameters = try #require(HueIntensity.high.parameters)
        let result = parameters.apply(to: HueRGB(red: 1, green: 1, blue: 1))
        #expect(abs(result.red - parameters.brightnessScale) < 1e-9)
        #expect(result.red == result.green && result.green == result.blue)
    }

    @Test func `a saturation boost pushes colours away from grey`() throws {
        let parameters = try #require(HueIntensity.intense.parameters)
        let source = HueRGB(red: 0.6, green: 0.4, blue: 0.4)
        let result = parameters.apply(to: source)
        #expect(result.red - result.green > source.red - source.green)
        #expect([result.red, result.green, result.blue].allSatisfy { (0 ... 1).contains($0) })
    }
}

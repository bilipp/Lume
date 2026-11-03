//
//  HueIntensity.swift
//  Lume
//
//  The light-sync intensity levels and the colour transform each one applies
//  to a smoothed channel colour before it is streamed.
//

import Foundation

/// A colour with every component in `0...1`.
nonisolated struct HueRGB: Hashable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = HueRGB(red: 0, green: 0, blue: 0)

    /// Rec. 709 luma.
    var luma: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    var maximumComponent: Double {
        max(red, green, blue)
    }

    func clamped() -> HueRGB {
        HueRGB(red: Self.clamp(red), green: Self.clamp(green), blue: Self.clamp(blue))
    }

    func channel(id: UInt8) -> HueStreamMessage.Channel {
        .normalized(id: id, red: red, green: green, blue: blue)
    }

    private static func clamp(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }
}

nonisolated enum HueIntensity: String, CaseIterable, Codable, Hashable {
    case off
    case subtle
    case moderate
    case high
    case intense

    nonisolated struct Parameters: Hashable {
        /// Multiplies every component after the saturation change.
        var brightnessScale: Double
        /// `1` keeps the picture's saturation, above `1` pushes colours away
        /// from their own grey.
        var saturationBoost: Double
        /// Seconds for an eased colour to cover ~63 % of a step.
        var smoothingTimeConstant: Double
        /// The lamps never go darker than this, so a black frame doesn't
        /// switch them off.
        var minimumBrightness: Double

        func apply(to color: HueRGB) -> HueRGB {
            let source = color.clamped()
            let grey = source.luma
            var result = HueRGB(
                red: (grey + (source.red - grey) * saturationBoost) * brightnessScale,
                green: (grey + (source.green - grey) * saturationBoost) * brightnessScale,
                blue: (grey + (source.blue - grey) * saturationBoost) * brightnessScale
            ).clamped()
            let peak = result.maximumComponent
            if peak <= 0 {
                result = HueRGB(red: minimumBrightness, green: minimumBrightness, blue: minimumBrightness)
            } else if peak < minimumBrightness {
                let lift = minimumBrightness / peak
                result = HueRGB(red: result.red * lift, green: result.green * lift, blue: result.blue * lift)
            }
            return result.clamped()
        }
    }

    /// Nil for `.off`: nothing is streamed.
    var parameters: Parameters? {
        switch self {
        case .off:
            nil
        case .subtle:
            Parameters(brightnessScale: 0.45, saturationBoost: 0.9, smoothingTimeConstant: 0.6, minimumBrightness: 0.04)
        case .moderate:
            Parameters(brightnessScale: 0.7, saturationBoost: 1.1, smoothingTimeConstant: 0.35, minimumBrightness: 0.03)
        case .high:
            Parameters(brightnessScale: 0.9, saturationBoost: 1.25, smoothingTimeConstant: 0.2, minimumBrightness: 0.02)
        case .intense:
            Parameters(brightnessScale: 1.0, saturationBoost: 1.4, smoothingTimeConstant: 0.1, minimumBrightness: 0.02)
        }
    }
}

//
//  HueFrameGrid+Linear.swift
//  Lume
//
//  Engines that sample the picture themselves report linear light; the grid
//  holds sRGB-encoded bytes like a decoded BGRA frame, so both paths reach
//  the lamps with the same tone.
//

import Foundation

nonisolated extension HueFrameGrid {
    nonisolated struct LinearColor: Hashable {
        var red: Float
        var green: Float
        var blue: Float
    }

    /// Row-major from the top-left, `width × height` colours, each component
    /// linear light on sRGB primaries where 1 is reference white. Nil when
    /// the count doesn't match.
    init?(width: Int, height: Int, linear colors: [LinearColor]) {
        guard width > 0, height > 0, colors.count == width * height else { return nil }
        var rgb: [UInt8] = []
        rgb.reserveCapacity(colors.count * 3)
        for color in colors {
            rgb.append(Self.encode(color.red))
            rgb.append(Self.encode(color.green))
            rgb.append(Self.encode(color.blue))
        }
        self.init(width: width, height: height, rgb: rgb)
    }

    /// The sRGB transfer function, clamped to 0...1, rounded to a byte.
    static func encode(_ linear: Float) -> UInt8 {
        guard linear.isFinite, linear > 0 else { return 0 }
        let clamped = min(linear, 1)
        let encoded = clamped <= 0.0031308
            ? clamped * 12.92
            : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return UInt8((encoded * 255).rounded())
    }
}

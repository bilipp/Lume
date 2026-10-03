//
//  LiveTVPalette.swift
//  Lume
//
//  The tvOS Live TV accent, and the glow colour a channel logo's tint yields.
//

import SwiftUI

nonisolated enum LiveTVPalette {
    /// `#5AA9FF`. Explicit because `Color.accentColor` resolves to white on tvOS.
    static let accent = Color(.sRGB, red: 90 / 255, green: 169 / 255, blue: 1, opacity: 1)

    /// The glow colour for a logo tint from `ChannelLogoTintCache`; the accent
    /// when the logo has no tint, or the tint is near-black or grey.
    ///
    /// Brightness is no reason to refuse one: the glow sits at half strength
    /// on a near-black backdrop with no text over it, so orange and yellow
    /// logos glow orange and yellow. (`TeamPalette.usableTint` refuses them —
    /// its floor keeps white text legible on a tinted card.)
    static func glowColor(forTintHex hex: String?) -> Color {
        guard let hex, isGlowTint(hex), let rgb = rgb(fromHex: hex) else { return accent }
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }

    /// Whether `hex` can tint the glow: coloured, and bright enough to show.
    /// Also what the logo extraction checks its candidates against, so a
    /// bright logo isn't dropped there before it reaches the glow.
    static func isGlowTint(_ hex: String) -> Bool {
        guard let rgb = rgb(fromHex: hex) else { return false }
        let brightest = max(rgb.red, rgb.green, rgb.blue)
        let spread = brightest - min(rgb.red, rgb.green, rgb.blue)
        return brightest >= minimumBrightness && spread >= minimumSpread
    }

    /// Below this the glow would not show against `#090B10`.
    private static let minimumBrightness = 0.15
    /// Below this the colour reads as grey or white, not as the logo's.
    private static let minimumSpread = 0.15

    private static func rgb(fromHex hex: String?) -> (red: Double, green: Double, blue: Double)? {
        guard var digits = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}

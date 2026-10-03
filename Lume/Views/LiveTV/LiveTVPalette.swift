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
    /// when the logo has no tint or the tint fails `TeamPalette`'s contrast floor.
    static func glowColor(forTintHex hex: String?) -> Color {
        TeamPalette.usableTint(fromHex: hex) ?? accent
    }
}

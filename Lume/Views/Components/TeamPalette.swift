//
//  TeamPalette.swift
//  Lume
//
//  The colour toolkit the Sports Hub draws its team tints, card gradients and
//  standings highlights from. ESPN hands us a team's `color`/`alternateColor`
//  as raw hex; many of those are near-white or near-black, which vanish (or
//  glare) as a subtle tint over the hub's dark card material. `TeamPalette`
//  applies a relative-luminance contrast floor so an unusable brand colour
//  degrades to a neutral tint instead of an illegible one.
//

import SwiftUI

/// A team's on-screen colours after the contrast floor, ready for tints and
/// gradients over the hub's dark base.
nonisolated struct TeamPalette: Equatable {
    let primary: Color
    let secondary: Color

    /// The tint substituted when a source colour is too light or too dark to
    /// read as a subtle wash over the dark card material.
    static let neutral = TeamPalette(primary: .secondary, secondary: .secondary)

    /// Opacity for a colour used as a card wash — the design brief's 25–35%.
    static let tintOpacity: Double = 0.3

    /// Minimum WCAG contrast a colour must have against white text before it is
    /// treated as usable rather than near-white.
    private static let minContrastAgainstWhite: Double = 3
    /// Relative luminance below which a colour reads as near-black.
    private static let nearBlackLuminance: Double = 0.02

    init(primary: Color, secondary: Color) {
        self.primary = primary
        self.secondary = secondary
    }

    /// Builds a palette from raw ESPN hexes (no leading `#` required). A hex that
    /// fails the contrast floor falls back to the neutral tint; a missing or
    /// unusable secondary falls back to the primary.
    init(primaryHex: String?, secondaryHex: String? = nil) {
        let resolvedPrimary = TeamPalette.usableTint(fromHex: primaryHex) ?? TeamPalette.neutral.primary
        let resolvedSecondary = TeamPalette.usableTint(fromHex: secondaryHex) ?? resolvedPrimary
        self.init(primary: resolvedPrimary, secondary: resolvedSecondary)
    }

    init(_ colors: SportsTeamColors) {
        self.init(primaryHex: colors.primaryHex, secondaryHex: colors.alternateHex)
    }

    /// The primary colour as a subtle wash for a fixture card background.
    var cardTint: Color {
        primary.opacity(Self.tintOpacity)
    }

    /// A diagonal home→away wash for a game-detail header, dimmed for legibility.
    static func gradient(home: TeamPalette, away: TeamPalette) -> LinearGradient {
        LinearGradient(
            colors: [home.primary.opacity(tintOpacity), away.primary.opacity(tintOpacity)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Returns the colour for `hex` only when it clears the contrast floor:
    /// `nil` when it is near-white (contrast against white text below 3:1) or
    /// near-black, so callers can substitute the neutral tint.
    static func usableTint(fromHex hex: String?) -> Color? {
        guard let hex, let rgba = teamPaletteRGBA(hex: hex) else { return nil }
        let luminance = teamPaletteRelativeLuminance(red: rgba.r, green: rgba.g, blue: rgba.b)
        let contrastAgainstWhite = 1.05 / (luminance + 0.05)
        if contrastAgainstWhite < minContrastAgainstWhite { return nil }
        if luminance < nearBlackLuminance { return nil }
        return Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: 1)
    }
}

nonisolated extension Color {
    /// `RRGGBB` or `RRGGBBAA`, with or without a leading `#`; nil when malformed.
    init?(hex: String) {
        guard let rgba = teamPaletteRGBA(hex: hex) else { return nil }
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

private nonisolated func teamPaletteRGBA(hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
    var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("#") { trimmed.removeFirst() }
    guard trimmed.count == 6 || trimmed.count == 8, let value = UInt64(trimmed, radix: 16) else {
        return nil
    }
    if trimmed.count == 6 {
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255,
            1
        )
    }
    return (
        Double((value >> 24) & 0xFF) / 255,
        Double((value >> 16) & 0xFF) / 255,
        Double((value >> 8) & 0xFF) / 255,
        Double(value & 0xFF) / 255
    )
}

private nonisolated func teamPaletteRelativeLuminance(red: Double, green: Double, blue: Double) -> Double {
    func linear(_ component: Double) -> Double {
        component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
}

nonisolated extension SportsFixture {
    /// The home team's tint palette; the neutral tint when there is no home side.
    var homePalette: TeamPalette {
        TeamPalette(primaryHex: home?.team.colorHex, secondaryHex: home?.team.alternateColorHex)
    }

    /// The away team's tint palette; the neutral tint when there is no away side.
    var awayPalette: TeamPalette {
        TeamPalette(primaryHex: away?.team.colorHex, secondaryHex: away?.team.alternateColorHex)
    }

    /// The competitor whose provider team id matches, if either side does.
    func team(forTeamId teamId: String?) -> SportsTeam? {
        guard let teamId else { return nil }
        if home?.team.teamId == teamId { return home?.team }
        if away?.team.teamId == teamId { return away?.team }
        return nil
    }

    /// The tint for a provider team id — the away palette for the away side, the
    /// home palette otherwise.
    func palette(forTeamId teamId: String?) -> TeamPalette {
        if let teamId, away?.team.teamId == teamId { return awayPalette }
        return homePalette
    }
}

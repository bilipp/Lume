//
//  StatusBadges.swift
//  Lume
//
//  The live badge (a red dot before "LIVE" in a tinted capsule, sized to its
//  host) and its quiet grey sibling for a finished game. Drawn by the sports
//  cards and detail headers and the Live TV guide hero. One definition each, so
//  a phone card, a tvOS card and the guide never drift. The playlist badge
//  shares their capsule to name a Combined grid item's source playlist.
//

import SwiftUI

/// "● LIVE" in a red-tinted capsule. `fontSize` sets the whole badge: the dot,
/// the padding and the text scale from it.
struct LiveBadge: View {
    var fontSize: CGFloat = 11

    var body: some View {
        StatusCapsule(fontSize: fontSize, tint: .red) {
            Circle()
                .fill(.red)
                .frame(width: fontSize * 0.55, height: fontSize * 0.55)
            Text("LIVE")
        }
        .accessibilityLabel(Text("Live"))
    }
}

/// "✓ FT" in a grey capsule — the live badge's shape and weight, without the
/// red, so a finished game reads as settled rather than as an alert.
struct EndedBadge: View {
    var fontSize: CGFloat = 11

    var body: some View {
        StatusCapsule(fontSize: fontSize, tint: .secondary) {
            Image(systemName: "checkmark")
                .font(.system(size: fontSize * 0.7, weight: .bold))
            Text("FT")
        }
        .accessibilityLabel(Text("Final"))
    }
}

/// The source playlist of a Combined grid item, in the capsule the status
/// badges use, backed by a material so it stays legible over poster artwork.
struct PlaylistBadge: View {
    let name: String

    #if os(tvOS)
        private static let fontSize: CGFloat = 20
    #else
        private static let fontSize: CGFloat = 10
    #endif

    var body: some View {
        StatusCapsule(fontSize: Self.fontSize, tint: .secondary) {
            Image(systemName: "rectangle.stack")
            Text(verbatim: name)
                .lineLimit(1)
        }
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityLabel(Text("from \(name)"))
    }
}

extension View {
    /// A poster card's provenance badge, inset in the artwork's bottom-leading
    /// corner. `nil` leaves the card as it is outside Combined.
    func playlistBadgeOverlay(_ name: String?) -> some View {
        overlay(alignment: .bottomLeading) {
            if let name {
                PlaylistBadge(name: name)
                    .padding(PosterCardMetrics.badgeInset)
            }
        }
    }
}

/// The capsule every badge here shares: tinted text over a faint wash of the same
/// tint, with the glyph, padding and kerning all scaled from `fontSize`.
private struct StatusCapsule<Content: View>: View {
    let fontSize: CGFloat
    let tint: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: fontSize * 0.4) {
            content()
        }
        .font(.system(size: fontSize, weight: .semibold))
        .kerning(fontSize * 0.04)
        .foregroundStyle(tint)
        .padding(.horizontal, fontSize * 0.7)
        .padding(.vertical, fontSize * 0.3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .accessibilityElement(children: .ignore)
    }
}

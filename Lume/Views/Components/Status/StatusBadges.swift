//
//  StatusBadges.swift
//  Lume
//
//  The live badge (a red dot before "LIVE" in a tinted capsule, sized to its
//  host) and its quiet grey sibling for a finished game. Drawn by the sports
//  cards and detail headers and the Live TV guide hero. One definition each, so
//  a phone card, a tvOS card and the guide never drift.
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

/// The capsule both badges share: tinted text over a faint wash of the same
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

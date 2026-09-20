//
//  SportsBadges.swift
//  Lume
//
//  The small shared marks the sports cards and detail headers draw: the live
//  badge (a red dot before "LIVE" in a tinted capsule, sized to its host) and a
//  competition crest with a quiet fallback glyph. One definition each, so a
//  phone card, a tvOS card and the detail header never drift.
//

import SwiftUI

/// "● LIVE" in a red-tinted capsule. `fontSize` sets the whole badge: the dot,
/// the padding and the text scale from it.
struct LiveBadge: View {
    var fontSize: CGFloat = 11

    var body: some View {
        HStack(spacing: fontSize * 0.4) {
            Circle()
                .fill(.red)
                .frame(width: fontSize * 0.55, height: fontSize * 0.55)
            Text("LIVE")
                .font(.system(size: fontSize, weight: .semibold))
                .kerning(fontSize * 0.04)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, fontSize * 0.7)
        .padding(.vertical, fontSize * 0.3)
        .background(Capsule().fill(.red.opacity(0.14)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Live"))
    }
}

/// A competition crest at `size`, with a court glyph while it loads or when
/// the provider sent none.
struct LeagueCrest: View {
    let url: URL?
    var size: CGFloat

    var body: some View {
        CachedAsyncImage(url: url, maxPixelSize: size * 2) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "sportscourt")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

//
//  PremiumBadge.swift
//  Lume
//
//  The small filled crown after a setting's title that marks it as a Lume Pro
//  feature for free users. A locked *action* swaps its own icon for a plain
//  `crown` instead (Add Playlist, Add Profile, Connect Trakt).
//

import SwiftUI

struct PremiumBadge: View {
    var body: some View {
        Image(systemName: "crown.fill")
            .font(Self.font)
            .foregroundStyle(Self.style)
            .accessibilityLabel("Lume Pro")
    }

    /// The accent elsewhere. tvOS takes the row's own foreground instead: the
    /// accent resolves to white there, which vanishes on a focused (white) row,
    /// while the row's foreground flips with the label.
    private static var style: AnyShapeStyle {
        #if os(tvOS)
            AnyShapeStyle(.primary)
        #else
            AnyShapeStyle(.tint)
        #endif
    }

    private static var font: Font {
        #if os(tvOS)
            .system(size: 20)
        #else
            .caption2
        #endif
    }
}

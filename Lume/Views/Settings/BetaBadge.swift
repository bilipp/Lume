//
//  BetaBadge.swift
//  Lume
//
//  The small outlined "Beta" tag after a setting's title that marks a feature
//  still in beta (Combined View). Sits beside `PremiumBadge` when both apply.
//

import SwiftUI

struct BetaBadge: View {
    var body: some View {
        Text("Beta", comment: "Tag after a setting's title marking a feature that is still in beta")
            .font(Self.font)
            .textCase(.uppercase)
            .foregroundStyle(Self.style)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Self.style, lineWidth: 1))
            .fixedSize()
    }

    /// Same rule as `PremiumBadge`: the accent elsewhere, the row's own
    /// foreground on tvOS, where the accent is white and vanishes on a focused
    /// row.
    private static var style: AnyShapeStyle {
        #if os(tvOS)
            AnyShapeStyle(.primary)
        #else
            AnyShapeStyle(.tint)
        #endif
    }

    private static var font: Font {
        #if os(tvOS)
            .system(size: 18, weight: .semibold)
        #else
            .caption2.weight(.semibold)
        #endif
    }

    private static var horizontalPadding: CGFloat {
        #if os(tvOS)
            10
        #else
            6
        #endif
    }
}

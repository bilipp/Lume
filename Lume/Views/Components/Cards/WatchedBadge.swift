//
//  WatchedBadge.swift
//  Lume
//
//  The checkmark that marks finished movies and episodes on their artwork, so
//  watched state reads at a glance instead of only through the context menu's
//  "Mark as Unwatched" (#206). Matches the tvOS episode still's checkmark.
//

import SwiftUI

enum WatchedBadgeMetrics {
    #if os(tvOS)
        static let size: CGFloat = 30
        static let inset: CGFloat = 10
    #else
        static let size: CGFloat = 18
        static let inset: CGFloat = 6
    #endif
}

extension View {
    /// Overlays a watched checkmark in the artwork's top-trailing corner. White
    /// over a dark disc stays legible on bright artwork, and avoids
    /// `Color.accentColor`, which resolves to white on tvOS.
    func watchedBadge(_ isWatched: Bool) -> some View {
        overlay(alignment: .topTrailing) {
            if isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: WatchedBadgeMetrics.size))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .padding(WatchedBadgeMetrics.inset)
                    .accessibilityLabel(Text("Watched"))
            }
        }
    }
}

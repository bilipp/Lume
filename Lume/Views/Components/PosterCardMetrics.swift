//
//  PosterCardMetrics.swift
//  Lume
//
//  Shared sizing for the poster cards used across the Home, Movies and Series
//  browse rows. tvOS needs noticeably larger cards, wider rail spacing and room
//  for the focus lift so titles and artwork never bleed into neighbouring cards
//  on the 10-foot UI; iOS keeps the compact phone-sized layout.
//

import SwiftUI

enum PosterCardMetrics {
    #if os(tvOS)
        static let posterWidth: CGFloat = 240
        static let posterHeight: CGFloat = 360
        static let cornerRadius: CGFloat = 12
        static let titleSpacing: CGFloat = 12
        static let titleFont: Font = .system(size: 24, weight: .medium)

        /// Gap between cards inside a horizontal browse rail.
        static let railSpacing: CGFloat = 48
        /// Vertical breathing room so the focus lift isn't clipped by the rail.
        static let railVerticalPadding: CGFloat = 28
        /// Height reserved for a rail: poster + two-line title + the focus lift.
        static let rowHeight: CGFloat = 470
        /// Minimum item width for the "Show All" adaptive grid.
        static let gridMinimum: CGFloat = 240
        static let gridSpacing: CGFloat = 48
        /// Inset between a transparent channel logo and its card plate.
        static let liveLogoInset: CGFloat = 32
    #else
        static let posterWidth: CGFloat = 120
        static let posterHeight: CGFloat = 180
        static let cornerRadius: CGFloat = 8
        static let titleSpacing: CGFloat = 8
        static let titleFont: Font = .caption

        static let railSpacing: CGFloat = 16
        static let railVerticalPadding: CGFloat = 0
        static let rowHeight: CGFloat = 220
        static let gridMinimum: CGFloat = 100
        static let gridSpacing: CGFloat = 16
        static let liveLogoInset: CGFloat = 16
    #endif
}

extension View {
    /// Applies the focus-aware card button style on tvOS (scale + shadow on
    /// focus) and the plain style elsewhere, so browse cards lift cleanly
    /// without overlapping neighbours.
    @ViewBuilder
    func posterCardButtonStyle() -> some View {
        #if os(tvOS)
            buttonStyle(TVCardButtonStyle(focusScale: 1.08))
        #else
            buttonStyle(.plain)
        #endif
    }
}

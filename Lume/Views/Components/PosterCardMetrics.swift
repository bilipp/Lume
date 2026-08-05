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

    /// Poster proportions, used to derive a card's height from a grid cell's
    /// width so grid artwork keeps the same shape as the rails' fixed cards.
    static let posterAspectRatio: CGFloat = posterWidth / posterHeight
}

extension View {
    /// Sizes a poster card's artwork.
    ///
    /// Rails lay cards out at the fixed `posterWidth`; the category and genre
    /// grids pass `fillsWidth: true` so the card takes its cell's width instead.
    /// An `.adaptive` column is only guaranteed to be *at least* `gridMinimum`
    /// wide, so on a wide window (macOS especially) a fixed-width card overflows
    /// its narrower cell, swallows `gridSpacing` and leaves the posters sitting
    /// flush against each other. Filling the cell keeps the gap exactly
    /// `gridSpacing`, matching the browse rails.
    ///
    /// tvOS keeps the fixed size in both places: `gridMinimum` already equals
    /// `posterWidth` there, so its cells never squeeze a card.
    @ViewBuilder
    func posterArtworkFrame(fillsWidth: Bool) -> some View {
        #if os(tvOS)
            frame(width: PosterCardMetrics.posterWidth, height: PosterCardMetrics.posterHeight)
        #else
            if fillsWidth {
                // A grid cell proposes a definite width and no height, which
                // `.fit` resolves into the matching 2:3 height; the artwork then
                // fills that box as an overlay and the caller's clip shape trims
                // the overhang.
                Color.clear
                    .aspectRatio(PosterCardMetrics.posterAspectRatio, contentMode: .fit)
                    .overlay { self }
            } else {
                frame(width: PosterCardMetrics.posterWidth, height: PosterCardMetrics.posterHeight)
            }
        #endif
    }

    /// Width for a poster card's title line, matching `posterArtworkFrame`.
    @ViewBuilder
    func posterTitleFrame(fillsWidth: Bool) -> some View {
        #if os(tvOS)
            frame(width: PosterCardMetrics.posterWidth, alignment: .leading)
        #else
            if fillsWidth {
                frame(maxWidth: .infinity, alignment: .leading)
            } else {
                frame(width: PosterCardMetrics.posterWidth, alignment: .leading)
            }
        #endif
    }

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

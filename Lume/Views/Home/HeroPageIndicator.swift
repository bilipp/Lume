//
//  HeroPageIndicator.swift
//  Lume
//
//  The hero carousel's slide dots, shared by the iOS/macOS carousel
//  (`HomeHeroCarousel`) and the tvOS immersive home (`TVHomeScreen`).
//

import SwiftUI

/// The carousel's dots. Inactive slides are small circles; the active slide
/// stretches into a capsule "track" whose fill grows with `progress`, reading as
/// a loading bar that previews when the carousel will jump to the next slide.
struct HeroPageIndicator: View {
    let count: Int
    /// Index of the active slide (0-based, over the real items).
    let activeIndex: Int
    /// Fill of the active capsule, 0…1.
    let progress: Double

    private let dotSize: CGFloat = 7
    private let activeWidth: CGFloat = 28
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0 ..< count, id: \.self) { index in
                let isActive = index == activeIndex
                // Always a Capsule (a 7×7 capsule reads as a circle) so the
                // active dot can smoothly stretch/contract on a page change
                // instead of swapping shapes and losing its animation identity.
                Capsule()
                    .fill(Color.white.opacity(isActive ? 0.35 : 0.4))
                    .frame(width: isActive ? activeWidth : dotSize, height: dotSize)
                    .overlay(alignment: .leading) {
                        if isActive {
                            Capsule()
                                .fill(Color.white)
                                // Tracks `progress` directly (no animation) so the
                                // fill steps with the tick rather than lagging it.
                                .frame(width: activeWidth * progress, height: dotSize)
                        }
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        // Scope the animation to the active-dot stretch on page change; the
        // per-tick fill changes happen in other passes and stay unanimated.
        .animation(.easeInOut(duration: 0.35), value: activeIndex)
    }
}

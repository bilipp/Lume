//
//  TVHomeFold.swift
//  Lume
//
//  Geometry and scroll-snapping for the immersive tvOS home in
//  `TVHomeScreen.swift`: the shared layout metrics, the three fold zones the
//  scroll can rest in, and the `ScrollTargetBehavior` that snaps focus-driven
//  scrolls between them.
//
//  tvOS fully owns focus and scrolling — the snap behavior only retargets
//  where a focus-driven scroll comes to REST; it never re-layouts content in
//  response to focus, which the focus engine cannot tolerate (see the earlier
//  collapse-on-focus attempt that had to be reverted).
//

#if os(tvOS)

    import SwiftUI

    // MARK: - Geometry

    enum TVHomeMetrics {
        /// Scroll content reserved below the showcase so the first row teases at
        /// the bottom of the screen (includes the `rowSpacing` gap above it).
        static let rowPeek: CGFloat = 198
        /// Hero strip that stays visible at the top after the first scroll down.
        static let heroStrip: CGFloat = 280
        /// Vertical gap between the showcase and the rows / between rows.
        static let rowSpacing: CGFloat = 28
    }

    // MARK: - Fold zones

    /// Where the home scroll is resting relative to the hero fold.
    enum TVHomeZone: Equatable {
        /// Hero fills the screen; the first row peeks at the bottom.
        case expanded
        /// One step down: hero strip at the top, first row parked mid-screen.
        case strip
        /// Hero offscreen; native row browsing.
        case rows

        init(offset: CGFloat, showcaseHeight: CGFloat) {
            let collapsed = showcaseHeight - TVHomeMetrics.heroStrip
            if showcaseHeight <= 0 || offset < collapsed * 0.5 {
                self = .expanded
            } else if offset < showcaseHeight - 40 {
                self = .strip
            } else {
                self = .rows
            }
        }
    }

    /// Snaps focus-driven scrolls to the three fold stages. The decision is based
    /// on the zone the scroll STARTED in plus the proposed resting offset, so the
    /// same target range can resolve differently for "down from hero" vs "up from
    /// the rows" without ever inspecting focus.
    struct TVHomeFoldBehavior: ScrollTargetBehavior {
        var zone: TVHomeZone
        var showcaseHeight: CGFloat

        func updateTarget(_ target: inout ScrollTarget, context _: TargetContext) {
            guard showcaseHeight > 0 else { return }
            let collapsed = showcaseHeight - TVHomeMetrics.heroStrip
            let proposed = target.rect.origin.y

            switch zone {
            case .expanded:
                // Small targets (the focus engine nudging the scroll a few
                // points to track the focused hero while its content swaps)
                // are pinned BACK to exactly 0 — merely returning would let
                // each nudge stick and the rows visibly drift while paging.
                if proposed < showcaseHeight * 0.3 {
                    target.rect.origin.y = 0
                    return
                }
                // First step down parks at the strip; a bigger jump (rapid
                // double-press landing two rows deep) skips straight past it.
                target.rect.origin.y = proposed <= collapsed + 120
                    ? collapsed
                    : max(proposed, showcaseHeight)

            case .strip:
                // Horizontal moves along the parked row: pin to the exact
                // strip offset so focus-tracking nudges can't accumulate.
                if abs(proposed - collapsed) < 40 {
                    target.rect.origin.y = collapsed
                    return
                }
                // Up restores the full hero; down hides it completely.
                target.rect.origin.y = proposed < collapsed ? 0 : max(proposed, showcaseHeight)

            case .rows:
                // Deep in the rows scrolling is fully native.
                if proposed > showcaseHeight { return }
                // Mirrors Apple's fold sample: a target that would reveal only a
                // sliver of the hero settles hidden; revealing more than ~30%
                // (focus actually moved onto the hero) expands it fully.
                target.rect.origin.y = proposed > showcaseHeight * 0.7 ? showcaseHeight : 0
            }
        }
    }

#endif

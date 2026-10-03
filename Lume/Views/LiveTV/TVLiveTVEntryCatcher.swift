//
//  TVLiveTVEntryCatcher.swift
//  Lume
//
//  Down from the tab bar into the tvOS Guide. Most tab items sit above the
//  guide's programmes, some above the category rail, and the guide's only
//  focus target is a narrow strip at its leading edge — so a vertical search
//  from a tab item finds the rail, or a strip it doesn't overlap. A
//  full-width, invisible band just below the tab bar overlaps every item and
//  hands the focus it catches on to the guide.
//

#if os(tvOS)
    import SwiftUI

    /// Which of the Live TV screen's focus regions hold real focus. A
    /// reference read only by the catcher, so focus moving between regions
    /// never re-renders the screen.
    @MainActor @Observable
    final class TVLiveTVFocusRegions {
        var railFocused = false
        var guideFocused = false
        /// Counted, not flagged: a category switch mounts the new guide
        /// before the old one's `onDisappear`.
        var mountedGuides = 0

        /// Only while focus is outside the screen, so Up from the rail's first
        /// category or the guide's top row still reaches the tab bar. And only
        /// with a guide mounted to hand focus to — an empty category would
        /// leave focus stranded on the band.
        var catchesEntry: Bool {
            mountedGuides > 0 && !railFocused && !guideFocused
        }
    }

    /// Reads `regions` here, not in the screen's overlay, so focus moving
    /// between regions re-renders only this view.
    struct TVLiveTVEntryCatcher: View {
        let regions: TVLiveTVFocusRegions
        let onEntry: () -> Void

        var body: some View {
            TVTabBarEntryCatcher(isEnabled: regions.catchesEntry, onEntry: onEntry)
                .accessibilityHidden(true)
                // Raised into the gap between the tab bar and the screen's
                // top. Measured on tvOS 26.5: the tab bar ends at y ≈ 114 and
                // the screen starts at 158, so the band sits at y ≈ 130.
                .alignmentGuide(.top) { $0[.top] + 28 }
        }
    }
#endif

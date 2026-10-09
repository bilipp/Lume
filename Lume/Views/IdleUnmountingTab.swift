//
//  IdleUnmountingTab.swift
//  Lume
//
//  Unmounts a tab that has sat unshown for a while (iOS/macOS).
//
//  `TabView` keeps every visited tab's hierarchy alive, and with it every
//  `@Query` inside: a catalog save — a favorite, an enrichment batch, an
//  indexer chunk, a guide refresh — re-fetched and re-rendered Home, Movies,
//  Series and Live TV together, whichever one was on screen. That was 62-74% of
//  a tab switch's SQL in the September audit. tvOS already renders only the
//  selected tab (`MainTabView.activeOnly`), where view state resets anyway.
//
//  Here a quick back-and-forth keeps the tab exactly as it was, scroll position
//  included. Only a tab left alone for `idleDelay` is torn down; its navigation
//  stack and Live TV's section live in `DeepLinkRouter` and come back with it,
//  and it opens at the top of its scroll.
//

import SwiftUI

struct IdleUnmountingTab<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: () -> Content

    /// Whether the tab's hierarchy is built. Starts false so a tab never
    /// visited isn't built at all.
    @State private var isMounted = false

    /// Whether the tab is on screen. A tab the iPhone tab bar overflows into
    /// "More" is shown without `TabView` ever writing its value to the
    /// selection, so `isSelected` alone left it a blank `Color.clear`.
    @State private var isVisible = false

    /// Long enough to cover checking another tab and coming straight back.
    static var idleDelay: Duration {
        .seconds(60)
    }

    private var isActive: Bool {
        isSelected || isVisible
    }

    var body: some View {
        Group {
            if isMounted || isActive {
                content()
            } else {
                Color.clear
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: isActive) {
            guard !isActive else {
                isMounted = true
                return
            }
            try? await Task.sleep(for: Self.idleDelay)
            guard !Task.isCancelled else { return }
            isMounted = false
        }
    }
}

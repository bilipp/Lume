//
//  ContentRestrictionProvider.swift
//  Lume
//
//  Derives `ContentRestriction` from the catalog and injects it, for scenes that
//  do not inherit `MainTabView`'s environment. The macOS player is its own
//  `WindowGroup`, so without this it resolves the permissive `@Entry` default
//  and a child profile can surf into a category a parent locked.
//
//  This deliberately repeats `MainTabView`'s derivation rather than sharing it.
//  `@Query` needs a view to live in, and `MainTabView` reads the restriction in
//  its own body as well as injecting it — so folding the two together would mean
//  splitting the app's root into a provider plus a content view. If the inputs
//  here ever change, change `MainTabView.contentRestriction` to match: two
//  scenes disagreeing about what a child may watch is the failure this guards.
//

import SwiftData
import SwiftUI

struct ContentRestrictionProvider<Content: View>: View {
    // Optional so previews (which don't inject it) don't crash.
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Query(filter: #Predicate<Category> { $0.isRestricted }) private var restrictedCategories: [Category]
    @Query(filter: #Predicate<Category> { $0.isHidden }) private var hiddenCategories: [Category]

    /// See `ContentRestrictionMemo` — building a restriction digests every
    /// excluded id, and this body re-runs on every catalog write.
    @State private var restrictionMemo = ContentRestrictionMemo()

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var contentRestriction: ContentRestriction {
        restrictionMemo.restriction(
            isActive: profileManager?.activeProfileIsChild ?? false,
            restricted: Set(restrictedCategories.map(\.id)),
            hidden: Set(hiddenCategories.map(\.id))
        )
    }

    var body: some View {
        content
            .environment(\.contentRestriction, contentRestriction)
    }
}

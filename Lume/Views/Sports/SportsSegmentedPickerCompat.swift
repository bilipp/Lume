//
//  SportsSegmentedPickerCompat.swift
//  Lume
//
//  `.pickerStyle(.segmented)` is unavailable on tvOS, but the shared iOS/macOS
//  hub screens (SportsHubView, LeagueDetailView, GameDetailSections) still have
//  to compile for the tvOS target — at runtime tvOS uses the purpose-built
//  `TVSportsHubScreen` instead. This one modifier keeps that `#if` in a single
//  place so it does not sit inline in a modifier chain (which SwiftFormat would
//  reindent and break).
//

import SwiftUI

extension View {
    @ViewBuilder
    func hubSegmentedPickerStyle() -> some View {
        #if os(tvOS)
            self
        #else
            pickerStyle(.segmented)
        #endif
    }

    /// Inline title on iPhone/iPad so the hub's scope menu (or a sheet's own
    /// header) reads as the title instead of a second large heading beneath it.
    @ViewBuilder
    func hubInlineNavigationTitle() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }
}

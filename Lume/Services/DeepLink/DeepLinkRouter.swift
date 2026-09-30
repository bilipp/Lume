//
//  DeepLinkRouter.swift
//  Lume
//

import SwiftUI

/// Shared navigation state a deep link drives: the selected tab and the Movies/
/// Series navigation stacks. `MainTabView` owns it and injects it into the
/// environment; `MoviesView` and `SeriesView` bind their `NavigationStack` to the
/// matching path so an `onOpenURL` push lands in the right tab.
///
/// It also holds the tab state that has to outlive the tab's view: tabs are
/// unmounted when not shown (tvOS) or after sitting unshown for a while
/// (`IdleUnmountingTab`, iOS/macOS), and what the viewer navigated to should
/// still be there when they come back.
@MainActor
@Observable
final class DeepLinkRouter {
    var selectedTab: AppTab = .home
    var moviesPath = NavigationPath()
    var seriesPath = NavigationPath()
    var sportsPath = NavigationPath()
    var homePath = NavigationPath()
    /// Live TV's selected rail section, and the playlist it was seeded for.
    var liveTVSection: LiveTVSection?
    var liveTVSeededPrefix: String?
    #if os(tvOS)
        /// Whether Multi-View is covering the app. It is presented from
        /// `MainTabView` — above the tab bar — as a plain overlay rather than a
        /// `fullScreenCover`, because a tvOS cover always dismisses itself on
        /// Menu. That would make it impossible for Menu to dismiss only
        /// Multi-View's own controls overlay, which is what a viewer expects
        /// while the controls are up.
        /// Non-nil while Multi-View is up; carries the channels it opened with,
        /// when it was started from a channel's long-press menu rather than the
        /// rail button.
        var multiViewLaunch: MultiViewLaunch?

        var isMultiViewPresented: Bool {
            multiViewLaunch != nil
        }

        /// Whether the playlist/profile quick-switch modal is covering the app.
        /// Like Multi-View it is presented from `MainTabView` as a plain overlay
        /// rather than a `fullScreenCover`, because a tvOS cover always dismisses
        /// itself on Menu and nothing stops it — neither `onExitCommand` nor
        /// `interactiveDismissDisabled`. The modal needs Menu for itself so a PIN
        /// pad nested over it can consume the press first.
        var isQuickSwitchPresented = false
    #endif
}

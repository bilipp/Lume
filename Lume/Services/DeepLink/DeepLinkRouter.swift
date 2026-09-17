//
//  DeepLinkRouter.swift
//  Lume
//

import SwiftUI

/// Shared navigation state a deep link drives: the selected tab and the Movies/
/// Series navigation stacks. `MainTabView` owns it and injects it into the
/// environment; `MoviesView` and `SeriesView` bind their `NavigationStack` to the
/// matching path so an `onOpenURL` push lands in the right tab.
@MainActor
@Observable
final class DeepLinkRouter {
    var selectedTab: AppTab = .home
    var moviesPath = NavigationPath()
    var seriesPath = NavigationPath()
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

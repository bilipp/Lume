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
}

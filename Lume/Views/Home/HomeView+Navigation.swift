//
//  HomeView+Navigation.swift
//  Lume
//
//  Home's navigation stack, driven from `DeepLinkRouter` so a pushed detail
//  screen survives the tab being unmounted (see `IdleUnmountingTab`). Split out
//  of HomeView.swift, which sits at SwiftLint's file-length limit.
//

import SwiftUI

extension HomeView {
    /// Previews have no router; pushes there simply don't persist.
    var homePath: Binding<NavigationPath> {
        guard let pathRouter else { return .constant(NavigationPath()) }
        return Binding(get: { pathRouter.homePath }, set: { pathRouter.homePath = $0 })
    }

    /// The Downloads row's "See All": pushes the full Downloads list.
    func showAllDownloads() {
        pathRouter?.homePath.append(HomeDownloadsRoute())
    }
}

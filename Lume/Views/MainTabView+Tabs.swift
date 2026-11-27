//
//  MainTabView+Tabs.swift
//  Lume
//

import SwiftUI

extension MainTabView {
    #if os(tvOS)
        func mainTab(_ tab: MainTab, selection: AppTab) -> some TabContent<AppTab> {
            Tab(value: tab.appTab) {
                activeOnly(tab.appTab, selection: selection) { rootView(tab) }
            } label: {
                Text(tab.title)
            }
        }
    #else
        func mainTab(_ tab: MainTab, selection: AppTab) -> some TabContent<AppTab> {
            Tab(tab.title, systemImage: tab.systemImage, value: tab.appTab) {
                IdleUnmountingTab(isSelected: selection == tab.appTab) { rootView(tab) }
            }
        }
    #endif

    @ViewBuilder
    private func rootView(_ tab: MainTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .movies: MoviesView()
        case .series: SeriesView()
        case .liveTV: LiveTVView()
        case .sports:
            #if os(tvOS)
                TVSportsHubScreen()
            #else
                SportsHubView()
            #endif
        }
    }
}

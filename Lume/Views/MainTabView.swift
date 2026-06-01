//
//  MainTabView.swift
//  Lume
//
//  Main tab-based navigation for the app
//

import SwiftData
import SwiftUI

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var playlists: [Playlist]

    @State private var navigationPath = NavigationPath()

    /// Playlists for which we've already kicked off an initial sync this session,
    /// so a view update doesn't start a second one while the first is running.
    @State private var initialSyncStarted: Set<UUID> = []

    #if os(tvOS)
        /// Default to Home even though Search is placed first in the tab bar.
        @State private var selectedTab: TabSelection = .home

        private enum TabSelection: Hashable {
            case search, home, movies, series, liveTV, settings
        }
    #endif

    var body: some View {
        tabView
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
        .task(id: playlists.count) {
            startPendingInitialSyncs()
        }
    }

    #if os(tvOS)
        private var tabView: some View {
            TabView(selection: $selectedTab) {
                Tab(value: TabSelection.search) {
                    SearchView()
                } label: {
                    Image(systemName: "magnifyingglass")
                }

                Tab(value: TabSelection.home) {
                    HomeView()
                } label: {
                    Text("Home")
                }

                Tab(value: TabSelection.movies) {
                    MoviesView()
                } label: {
                    Text("Movies")
                }

                Tab(value: TabSelection.series) {
                    SeriesView()
                } label: {
                    Text("Series")
                }

                Tab(value: TabSelection.liveTV) {
                    LiveTVView()
                } label: {
                    Text("Live TV")
                }

                Tab(value: TabSelection.settings) {
                    SettingsView()
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
    #else
        private var tabView: some View {
            TabView {
                Tab("Home", systemImage: "house") {
                    HomeView()
                }

                Tab("Movies", systemImage: "film") {
                    MoviesView()
                }

                Tab("Series", systemImage: "tv") {
                    SeriesView()
                }

                Tab("Live TV", systemImage: "antenna.radiowaves.left.and.right") {
                    LiveTVView()
                }

                Tab(role: .search) {
                    SearchView()
                }
            }
        }
    #endif

    // MARK: - Initial sync

    private func startPendingInitialSyncs() {
        for playlist in playlists where shouldStartInitialSync(playlist) {
            initialSyncStarted.insert(playlist.id)

            Task {
                let manager = ContentSyncManager(modelContainer: modelContext.container)
                try? await manager.syncPlaylist(playlist, full: true)
            }
        }
    }

    private func shouldStartInitialSync(_ playlist: Playlist) -> Bool {
        playlist.syncEnabled
            && playlist.lastSyncDate == nil
            && playlist.syncStatus != .syncing
            && !initialSyncStarted.contains(playlist.id)
    }
}

#Preview("No Playlists") {
    MainTabView()
}

#Preview("With Playlists") {
    MainTabView()
        .modelContainer(for: Playlist.self, inMemory: true) { result in
            if case let .success(container) = result {
                let playlist = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "user", password: "pass")
                container.mainContext.insert(playlist)
            }
        }
}

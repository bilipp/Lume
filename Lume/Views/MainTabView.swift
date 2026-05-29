//
//  MainTabView.swift
//  Lume
//
//  Main tab-based navigation for the app
//

import SwiftUI
import SwiftData

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var playlists: [Playlist]

    @State private var selectedTab: TabItem = .home
    @State private var navigationPath = NavigationPath()

    /// Playlists for which we've already kicked off an initial sync this session,
    /// so a view update doesn't start a second one while the first is running.
    @State private var initialSyncStarted: Set<UUID> = []

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(value: .home) {
                HomeView()
            } label: {
                Label("Home", systemImage: "house")
            }

            Tab(value: .movies) {
                MoviesView()
            } label: {
                Label("Movies", systemImage: "film")
            }

            Tab(value: .series) {
                SeriesView()
            } label: {
                Label("Series", systemImage: "tv")
            }

            Tab(value: .liveTV) {
                LiveTVView()
            } label: {
                Label("Live TV", systemImage: "antenna.radiowaves.left.and.right")
            }

            Tab(value: .settings) {
                SettingsView()
            } label: {
                Label("Settings", systemImage: "gear")
            }
        }
        .task(id: playlists.count) {
            startPendingInitialSyncs()
        }
    }

    // MARK: - Initial sync

    /// Starts a one-time background sync for any playlist that has never been
    /// synced. Triggered when a playlist is first added (first run or via the
    /// Settings sheet) so freshly-added content shows up without the user having
    /// to open the playlist and tap "Sync Now".
    private func startPendingInitialSyncs() {
        for playlist in playlists where shouldStartInitialSync(playlist) {
            initialSyncStarted.insert(playlist.id)

            // Detached from the view's task lifetime so a subsequent view update
            // (which re-runs .task(id:)) can't cancel an in-flight sync.
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

    enum TabItem {
        case home
        case movies
        case series
        case liveTV
        case settings
    }
}

#Preview {
    MainTabView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

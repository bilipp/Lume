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

    @State private var navigationPath = NavigationPath()

    /// Playlists for which we've already kicked off an initial sync this session,
    /// so a view update doesn't start a second one while the first is running.
    @State private var initialSyncStarted: Set<UUID> = []

    var body: some View {
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
        .tabBarMinimizeBehavior(.onScrollDown)
        .task(id: playlists.count) {
            startPendingInitialSyncs()
        }
    }

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
            if case .success(let container) = result {
                let p = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "user", password: "pass")
                container.mainContext.insert(p)
            }
        }
}

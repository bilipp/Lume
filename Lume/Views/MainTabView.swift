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
    @Environment(\.scenePhase) private var scenePhase
    @Query private var playlists: [Playlist]

    @AppStorage(SyncFrequency.storageKey) private var syncFrequencyRaw: String = SyncFrequency.defaultValue.rawValue
    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""

    @State private var navigationPath = NavigationPath()

    /// Playlists for which we've kicked off an auto-sync that hasn't finished
    /// yet, so a view update doesn't start a second one before the playlist's
    /// `syncStatus` flips to `.syncing`. An id is removed once its task
    /// completes, so a playlist that goes stale again later (e.g. on a long
    /// foreground session) can re-sync.
    @State private var autoSyncStarted: Set<UUID> = []

    private var syncFrequency: SyncFrequency {
        SyncFrequency.resolve(syncFrequencyRaw)
    }

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
            // On launch (and whenever a playlist is added) sync any playlist that
            // is due per the configured frequency.
            startDueAutoSyncs()
        }
        .onChange(of: selectedPlaylistID) {
            // On playlist switch, sync the newly selected one if it's due.
            syncSelectedPlaylistIfDue()
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning to the foreground re-checks staleness — for a long-lived
            // app this is the practical equivalent of "on launch".
            if phase == .active {
                startDueAutoSyncs()
            }
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

    // MARK: - Automatic sync

    /// Kicks off a background sync for every playlist that is due per the
    /// configured frequency (covers the never-synced first launch too).
    private func startDueAutoSyncs() {
        for playlist in playlists where shouldAutoSync(playlist) {
            autoSync(playlist)
        }
    }

    /// Syncs the currently selected playlist if it is due. Called on playlist
    /// switch so the content you're about to browse is refreshed.
    private func syncSelectedPlaylistIfDue() {
        guard let playlist = playlists.active(for: selectedPlaylistID),
              shouldAutoSync(playlist) else { return }
        autoSync(playlist)
    }

    private func shouldAutoSync(_ playlist: Playlist) -> Bool {
        AutoSync.shouldSync(
            syncEnabled: playlist.syncEnabled,
            status: playlist.syncStatus,
            lastSyncDate: playlist.lastSyncDate,
            frequency: syncFrequency,
            alreadyStarted: autoSyncStarted.contains(playlist.id)
        )
    }

    /// Starts a silent background sync, tracking the playlist as in-flight so a
    /// rapid view update doesn't double-trigger, and clearing it when done.
    private func autoSync(_ playlist: Playlist) {
        let playlistId = playlist.id
        autoSyncStarted.insert(playlistId)

        Task {
            let manager = ContentSyncManager(modelContainer: modelContext.container)
            try? await manager.syncPlaylist(playlist, full: true)
            await MainActor.run { _ = autoSyncStarted.remove(playlistId) }
        }
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

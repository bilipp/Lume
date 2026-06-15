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
    // Optional so previews (which don't inject it) don't crash.
    @Environment(PlaylistSwitchModel.self) private var playlistSwitch: PlaylistSwitchModel?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Query private var playlists: [Playlist]
    /// Categories marked restricted. Fetched once here so a single source feeds
    /// the restriction context every content surface reads from the environment.
    @Query(filter: #Predicate<Category> { $0.isRestricted }) private var restrictedCategories: [Category]

    @AppStorage(SyncFrequency.storageKey) private var syncFrequencyRaw: String = SyncFrequency.defaultValue.rawValue
    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""

    @State private var navigationPath = NavigationPath()

    /// Playlists waiting to be auto-synced, and the one currently shown in the
    /// blocking progress cover. Auto-sync is presented (not silent) so the user
    /// sees progress and waits for it to finish — most importantly right after
    /// adding a playlist, when the app would otherwise look empty and broken.
    @State private var syncQueue: [Playlist] = []
    @State private var activeSyncPlaylist: Playlist?

    /// Playlists we've already auto-synced (or attempted) this session, so the
    /// launch / switch / foreground triggers don't re-present the cover for one
    /// that's already been handled.
    @State private var autoSyncAttempted: Set<UUID> = []

    private var syncFrequency: SyncFrequency {
        SyncFrequency.resolve(syncFrequencyRaw)
    }

    /// UI tests seed a fake playlist; auto-sync would present a blocking cover
    /// that can never succeed against the stub server, so skip it there.
    private var isUITesting: Bool {
        CommandLine.arguments.contains("-ui-testing")
    }

    #if os(tvOS)
        /// Default to Home even though Search is placed first in the tab bar.
        @State private var selectedTab: TabSelection = .home

        private enum TabSelection: Hashable {
            case search, home, movies, series, liveTV, settings
        }
    #endif

    /// Hides restricted categories (and their content) from every browse, Home
    /// and Search surface while a child profile is active.
    private var contentRestriction: ContentRestriction {
        ContentRestriction(
            isActive: profileManager?.activeProfileIsChild ?? false,
            restrictedCategoryIDs: Set(restrictedCategories.map(\.id))
        )
    }

    var body: some View {
        tabView
            .environment(\.contentRestriction, contentRestriction)
        #if os(iOS)
            .tabBarMinimizeBehavior(.onScrollDown)
        #endif
            .task(id: playlists.count) {
                // On launch (and whenever a playlist is added) sync any playlist that
                // is due per the configured frequency.
                enqueueDueSyncs(playlists)
            }
            .onChange(of: selectedPlaylistID) {
                // On playlist switch, sync the newly selected one if it's due.
                if let playlist = playlists.active(for: selectedPlaylistID) {
                    enqueueDueSyncs([playlist])
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // Returning to the foreground re-checks staleness — for a long-lived
                // app this is the practical equivalent of "on launch".
                if phase == .active {
                    enqueueDueSyncs(playlists)
                }
            }
            .syncCover(item: $activeSyncPlaylist, onDismiss: promoteNextIfIdle)
            .overlay {
                if playlistSwitch?.isSwitching == true {
                    PlaylistSwitchOverlay(playlistName: playlistSwitch?.targetName ?? "")
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: playlistSwitch?.isSwitching)
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

    /// Enqueues every due playlist for a blocking, progress-visible sync and
    /// presents the first one. Covers the never-synced first launch (where
    /// `lastSyncDate == nil` makes a playlist due) as well as periodic refreshes.
    private func enqueueDueSyncs(_ candidates: [Playlist]) {
        guard !isUITesting else { return }

        for playlist in candidates where shouldAutoSync(playlist) {
            autoSyncAttempted.insert(playlist.id)
            syncQueue.append(playlist)
        }
        promoteNextIfIdle()
    }

    private func shouldAutoSync(_ playlist: Playlist) -> Bool {
        AutoSync.shouldSync(
            syncEnabled: playlist.syncEnabled,
            status: playlist.syncStatus,
            lastSyncDate: playlist.lastSyncDate,
            frequency: syncFrequency,
            alreadyStarted: autoSyncAttempted.contains(playlist.id)
        )
    }

    /// Presents the next queued playlist's sync cover when none is showing. The
    /// `SyncProgressView` auto-starts the sync and dismisses itself on success;
    /// the cover's `onDismiss` calls back here to advance the queue.
    private func promoteNextIfIdle() {
        guard activeSyncPlaylist == nil, !syncQueue.isEmpty else { return }
        activeSyncPlaylist = syncQueue.removeFirst()
    }
}

// MARK: - Sync cover presentation

private extension View {
    /// Presents the auto-sync progress UI as a blocking cover: a full-screen
    /// cover on iOS/tvOS (no swipe-to-dismiss), a sheet on macOS where
    /// `fullScreenCover` is unavailable.
    @ViewBuilder
    func syncCover(item: Binding<Playlist?>, onDismiss: @escaping () -> Void) -> some View {
        #if os(macOS)
            sheet(item: item, onDismiss: onDismiss) { playlist in
                SyncProgressView(playlist: playlist, autoStart: true)
                    .frame(minWidth: 420, minHeight: 480)
            }
        #else
            fullScreenCover(item: item, onDismiss: onDismiss) { playlist in
                SyncProgressView(playlist: playlist, autoStart: true)
            }
        #endif
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

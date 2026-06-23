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

    /// Selected tab and the Movies/Series navigation stacks, shared so an
    /// `onOpenURL` deep link can switch tabs and push a detail screen.
    @State private var router = DeepLinkRouter()

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

    /// Hides restricted categories (and their content) from every browse, Home
    /// and Search surface while a child profile is active.
    private var contentRestriction: ContentRestriction {
        ContentRestriction(
            isActive: profileManager?.activeProfileIsChild ?? false,
            restrictedCategoryIDs: Set(restrictedCategories.map(\.id))
        )
    }

    var body: some View {
        @Bindable var router = router
        return tabView(selection: $router.selectedTab)
            .environment(router)
            .environment(\.contentRestriction, contentRestriction)
        #if os(iOS)
            .tabBarMinimizeOnScrollDownIfAvailable()
        #endif
            .onOpenURL { url in
                handleDeepLink(url)
            }
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
        private func tabView(selection: Binding<AppTab>) -> some View {
            TabView(selection: selection) {
                Tab(value: AppTab.search) {
                    SearchView()
                } label: {
                    Image(systemName: "magnifyingglass")
                }

                Tab(value: AppTab.home) {
                    HomeView()
                } label: {
                    Text("Home")
                }

                Tab(value: AppTab.movies) {
                    MoviesView()
                } label: {
                    Text("Movies")
                }

                Tab(value: AppTab.series) {
                    SeriesView()
                } label: {
                    Text("Series")
                }

                Tab(value: AppTab.liveTV) {
                    LiveTVView()
                } label: {
                    Text("Live TV")
                }

                Tab(value: AppTab.settings) {
                    SettingsView()
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
    #else
        private func tabView(selection: Binding<AppTab>) -> some View {
            TabView(selection: selection) {
                Tab("Home", systemImage: "house", value: AppTab.home) {
                    HomeView()
                }

                Tab("Movies", systemImage: "film", value: AppTab.movies) {
                    MoviesView()
                }

                Tab("Series", systemImage: "tv", value: AppTab.series) {
                    SeriesView()
                }

                Tab("Live TV", systemImage: "antenna.radiowaves.left.and.right", value: AppTab.liveTV) {
                    LiveTVView()
                }

                Tab(value: AppTab.search, role: .search) {
                    SearchView()
                }
            }
        }
    #endif

    // MARK: - Deep links

    /// Resolves a `lume://movie/{tmdbId}` / `lume://series/{tmdbId}` link to a
    /// catalog item, switches to the matching tab and pushes its detail screen.
    /// Silently ignores unknown links and titles not present in the catalog
    /// (e.g. a tmdbId that was never synced or enriched).
    private func handleDeepLink(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        switch link {
        case let .movie(tmdbId):
            guard let movie = resolveMovie(tmdbId: tmdbId) else { return }
            router.selectedTab = .movies
            router.moviesPath = NavigationPath()
            router.moviesPath.append(movie)
        case let .series(tmdbId):
            guard let series = resolveSeries(tmdbId: tmdbId) else { return }
            router.selectedTab = .series
            router.seriesPath = NavigationPath()
            router.seriesPath.append(series)
        }
    }

    /// Finds a movie by `tmdbId`, preferring the active playlist but falling back
    /// to any other playlist's copy. Restricted categories stay hidden for a
    /// child profile.
    private func resolveMovie(tmdbId: Int) -> Movie? {
        let descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == tmdbId })
        let restriction = contentRestriction
        let matches = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { !restriction.hides(categoryID: $0.categoryId) }
        return matches.first { belongsToActivePlaylist($0.id) } ?? matches.first
    }

    private func resolveSeries(tmdbId: Int) -> Series? {
        let descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId })
        let restriction = contentRestriction
        let matches = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { !restriction.hides(categoryID: $0.categoryId) }
        return matches.first { belongsToActivePlaylist($0.id) } ?? matches.first
    }

    private func belongsToActivePlaylist(_ id: String) -> Bool {
        guard let activePlaylist = playlists.active(for: selectedPlaylistID) else { return true }
        return id.hasPrefix("\(activePlaylist.id.uuidString)-")
    }

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

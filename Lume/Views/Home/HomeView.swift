//
//  HomeView.swift
//  Lume
//
//  Default landing screen: Recently Watched, Favorites, For You (opt-in Pro recommendations),
//  Trending Movies/Series and the Trakt/Simkl/MDBList watchlists. Row order and visibility are
//  user-configurable (Settings › Layout › Home, see HomeLayoutSettings); rows render only with content.
//

import SwiftData
import SwiftUI

struct HomeView: View {
    @Namespace private var animationNamespace
    // Several members below are `internal` (not `private`) so the trending /
    // watchlist loading in `HomeView+Trending.swift` can drive them.
    @Environment(\.modelContext) var modelContext
    @Environment(\.contentRestriction) var restriction
    /// The playlists whose content is shown: one playlist, or the Combined
    /// members.
    @Environment(\.catalogScope) var catalogScope
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    @Query var playlists: [Playlist]
    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @AppStorage(SortStorageKey.movieCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue
    @AppStorage(SortStorageKey.movieContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @AppStorage(LibrarySettings.groupDuplicateTitlesKey)
    var groupDuplicateTitles = LibrarySettings.groupDuplicateTitlesDefault

    // Recently watched (capped — watch history is naturally bounded).
    @Query var watchedMovies: [Movie]
    @Query var watchedSeries: [Series]
    @Query private var watchedStreams: [LiveStream]

    // Favorites.
    @Query var favoriteMovies: [Movie]
    @Query var favoriteSeries: [Series]
    @Query private var favoriteStreams: [LiveStream]

    @State var trendingMovies: [HomeMediaItem] = []
    @State var trendingSeries: [HomeMediaItem] = []
    @State var watchlists: [HomeWatchlistSource: [HomeMediaItem]] = [:]
    /// Resume fractions for partially-watched series, keyed by series id and
    /// resolved off the main thread — see `SeriesResumeLoader`.
    @State private var seriesResume: [String: Double] = [:]
    /// Favorite, watched and progress across every copy of each title on
    /// screen, read by the rails and the hero (`TitleGroupStates`).
    @State var groupStates = TitleGroupStates.empty
    @AppStorage(PlayerSettings.Language.preferredAudioLanguagesKey)
    private var preferredAudioLanguagesRaw = PlayerSettings.Language.preferredAudioLanguagesDefault
    /// Decoded from `preferredAudioLanguagesRaw` once per change, not per
    /// `titleRanking` read.
    @State private var preferredLanguages = PlayerLanguageOptions.load().preferredAudioLanguages
    @AppStorage(RecommendationSettings.enabledKey) var recommendationsEnabled = RecommendationSettings.enabledDefault
    /// The user's chosen Home row order (Settings › Layout › Home). Falls back to
    /// the declaration order of `HomeSection` until they reorder.
    @AppStorage(HomeLayoutSettings.sectionOrderKey) private var sectionOrderRaw = ""
    /// Sections the user switched off, and opt-in ones they switched on (Settings ›
    /// Layout › Home). "For You" is gated by `recommendationsEnabled` instead.
    @AppStorage(HomeLayoutSettings.disabledSectionsKey) private var disabledSectionsRaw = ""
    @AppStorage(HomeLayoutSettings.enabledSectionsKey) private var enabledSectionsRaw = ""
    @AppStorage(HomeLayoutSettings.recentlyWatchedIncludesLiveTVKey)
    private var recentlyWatchedIncludesLiveTV = HomeLayoutSettings.recentlyWatchedIncludesLiveTVDefault
    /// Bumped by the DEBUG "Recalculate" action in Settings (always 0 otherwise);
    /// part of the task id so the row recomputes on demand.
    @AppStorage(RecommendationSettings.manualRecalculationKey) var recommendationsRecalcToken = 0
    @State var recommendations: [HomeMediaItem] = []
    /// False until the first recommendations pass completes, so the row can show
    /// a progress placeholder rather than an empty state on launch.
    @State var recommendationsLoaded = false
    @State var heroItems: [HeroItem] = []
    /// The home scroll view's height, which sizes the hero (re-measured on a fold or rotation).
    @State private var viewportHeight: CGFloat = 0
    @State var trendingState: HomeLoadState = .idle
    @State var trakt = TraktService.shared
    @State var simkl = SimklService.shared
    @State var mdblist = MDBListService.shared
    /// "For You" is a Lume Pro feature; observed so the row appears/disappears
    /// when entitlement changes.
    @State var premium = PremiumManager.shared
    // Observed so the For You row defers its (potentially heavy) recompute while
    // the device is busy syncing — and retries automatically once it isn't.
    @State var indexing = ContentIndexingService.shared
    @State var epgSync = EPGSyncService.shared
    /// Observed for the Home empty-state check, which mirrors the Sports rail.
    @State var sportsFollows = SportsFollowService.shared
    @State var sportsStore = SportsStore.shared
    @State var scopeMatcherMemo = CatalogScopeMatcherMemo()
    @State private var playingMedia: PlayableMedia?
    @State private var showingSync = false
    @State private var showingSettings = false
    /// Shown when a channel's "Start Multi-View" is picked without Lume Pro.
    @State private var showingPaywall = false
    @Environment(DeepLinkRouter.self) var pathRouter: DeepLinkRouter?
    #if os(tvOS)
        @Environment(DeepLinkRouter.self) var router
    #else
        /// Non-nil while Multi-View is up; carries the channel it opened with.
        @State var multiViewLaunch: MultiViewLaunch?
    #endif

    #if os(tvOS)
        /// Hero selected on the immersive home: a stable Button, not a
        /// NavigationLink, so paging the carousel never changes its identity.
        @State var selectedHero: HeroItem?
    #endif

    /// Movie and series rows read per rail: several copies of one title can
    /// fill the window, and grouping shows each title once
    /// (`HomeView.recentlyWatched`, `HomeView.favorites`).
    private static let watchedFetchLimit = 20 * TitleGrouping.overFetch
    private static let favoritesPerKind = 30
    private static let favoritesFetchLimit = favoritesPerKind * TitleGrouping.overFetch

    init() {
        // Recently watched: non-nil lastWatchedDate, newest first.
        var movies = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.lastWatchedDate != nil },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        movies.fetchLimit = Self.watchedFetchLimit
        _watchedMovies = Query(movies)

        var series = FetchDescriptor<Series>(
            predicate: #Predicate { $0.lastWatchedDate != nil },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        series.fetchLimit = Self.watchedFetchLimit
        _watchedSeries = Query(series)

        // Channels hidden in Content Management drop out here, the same way Live
        // TV drops them; a hidden *category* is handled by `excludingRestricted`.
        var streams = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.lastWatchedDate != nil && $0.isHidden == false },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        streams.fetchLimit = 20
        _watchedStreams = Query(streams)

        // Favorites: by the unified favorites order (Content Management →
        // Favorites), falling back to name; capped. The cross-type interleave
        // happens in the `favorites` accessor.
        var favMovies = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name)]
        )
        favMovies.fetchLimit = Self.favoritesFetchLimit
        _favoriteMovies = Query(favMovies)

        var favSeries = FetchDescriptor<Series>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name)]
        )
        favSeries.fetchLimit = Self.favoritesFetchLimit
        _favoriteSeries = Query(favSeries)

        var favStreams = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.isFavorite && $0.isHidden == false },
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name)]
        )
        favStreams.fetchLimit = 30
        _favoriteStreams = Query(favStreams)
    }

    var body: some View {
        NavigationStack(path: homePath) {
            Group {
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "house",
                        description: Text("Add a playlist in Settings to get started")
                    )
                } else if isEmpty {
                    ContentUnavailableView(
                        "Nothing Here Yet",
                        systemImage: "house",
                        description: Text("Watch something or mark titles as favorites and they'll show up here.")
                    )
                } else {
                    #if os(tvOS)
                        // Immersive Apple TV-style home: full-screen backdrop,
                        // teasing first row, fold-snapping scroll. Lives in
                        // `TVHomeScreen.swift`.
                        TVHomeScreen(
                            heroItems: heroItems,
                            onSelectHero: { selectedHero = $0 },
                            rows: { homeRows }
                        )
                        .tvQuickSwitchHint(interacted: selectedHero != nil)
                    #else
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 28) {
                                if !heroItems.isEmpty {
                                    HomeHeroCarousel(
                                        items: heroItems,
                                        heroHeight: HomeHeroCarousel.height(forViewport: viewportHeight)
                                    )
                                }
                                homeRows
                            }
                            .padding(.bottom)
                        }
                        .browseActivity()
                        .scrollIndicators(.hidden)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
                        // Only let content run under the nav bar when the hero
                        // backdrop is there to fill it; otherwise the first row
                        // would sit hidden behind the bar.
                        .ignoresSafeArea(edges: heroItems.isEmpty ? [] : .top)
                    #endif
                }
            }
            .profileMenuToolbar()
            .libraryToolbar(config: LibraryToolbarConfiguration(
                playlists: playlists,
                selectedPlaylistID: $selectedPlaylistID,
                categorySortRaw: $categorySortRaw,
                contentSortRaw: $contentSortRaw,
                showingSync: $showingSync,
                showingSettings: $showingSettings
            ))
            .navigationDestination(for: Movie.self) { movie in
                MovieDetailView(movie: movie, animationNamespace: animationNamespace)
                #if os(iOS)
                    .navigationTransition(.zoom(sourceID: movie.id, in: animationNamespace))
                #endif
            }
            .navigationDestination(for: Series.self) { series in
                SeriesDetailView(series: series, animationNamespace: animationNamespace)
                #if os(iOS)
                    .navigationTransition(.zoom(sourceID: series.id, in: animationNamespace))
                #endif
            }
            .homeDownloadsDestination()
            .homeHeroDestination(heroSelection, animationNamespace: animationNamespace)
            .environment(\.titleGroupStates, groupStates)
            .task(id: groupStateKey) {
                groupStates = TitleGroupStates.load(for: groupStateRequest, in: modelContext)
            }
            .onChange(of: preferredAudioLanguagesRaw) {
                preferredLanguages = PlayerLanguageOptions.load().preferredAudioLanguages
            }
            .task(id: trendingKey) {
                await loadTrending(cacheKey: trendingKey)
            }
            .task(id: watchlistsKey) {
                await loadWatchlists(scope: watchlistScope)
            }
            .task(id: recommendationsKey) {
                await loadRecommendations()
            }
            .task(id: seriesResumeKey) {
                await loadSeriesResume()
            }
            .task(id: sportsWarmKey) {
                warmSports()
            }
            .homePlayerCovers(playingMedia: $playingMedia, multiViewLaunch: multiViewLaunchSelection)
            .paywall(isPresented: $showingPaywall, highlight: .multiView)
        }
        .recordActionFlow(observesWhileVisible: false) // once, for every rail's channel menu
    }

    /// The horizontal rails, shared by the iOS/macOS scroll layout and the tvOS
    /// immersive home. Rows render in the user's chosen order (Settings › Layout ›
    /// Home); each only appears when it has content.
    private var homeRows: some View {
        ForEach(HomeLayoutSettings.resolve(orderRaw: sectionOrderRaw)) { section in
            homeRow(for: section)
        }
    }

    @ViewBuilder
    private func homeRow(for section: HomeSection) -> some View {
        if isSectionEnabled(section) {
            switch section {
            case .recentlyWatched:
                rail("Recently Watched", recentlyWatched, onRemove: removeFromRecentlyWatched)
            case .favorites:
                rail("Favorites", favorites)
            case .forYou:
                ForYouRow(
                    items: recommendations,
                    seriesResume: seriesResume,
                    isLoading: !recommendationsLoaded,
                    onPlayLive: playChannel,
                    onVote: vote,
                    animationNamespace: animationNamespace
                )
            case .trendingMovies:
                rail("Trending Movies", trendingMovies)
            case .trendingSeries:
                rail("Trending Series", trendingSeries)
            case .traktWatchlist, .simklWatchlist, .mdblistWatchlist:
                if let source = HomeWatchlistSource(section: section) {
                    rail(source.rowTitle, watchlists[source] ?? [])
                }
            case .sports:
                SportsHomeRail(isSyncBusy: isSyncBusy)
            case .downloads:
                HomeDownloadsRow(seriesResume: seriesResume, animationNamespace: animationNamespace, onSeeAll: showAllDownloads)
            }
        }
    }

    /// Whether `section` should render. "For You" follows the recommendations
    /// opt-in (which also gates its recompute); the rest follow the user's
    /// per-section switches.
    func isSectionEnabled(_ section: HomeSection) -> Bool {
        section == .forYou
            ? (recommendationsEnabled && premium.isPremium)
            : HomeLayoutSettings.isEnabled(section, disabledRaw: disabledSectionsRaw, enabledRaw: enabledSectionsRaw)
    }

    /// A standard Home rail that only renders when it has items. The Recently
    /// Watched rail passes `onRemove` to add its remove-from-history action.
    @ViewBuilder
    private func rail(
        _ title: LocalizedStringKey,
        _ items: [HomeMediaItem],
        onRemove: ((HomeMediaItem) -> Void)? = nil
    ) -> some View {
        if !items.isEmpty {
            HomeRow(
                title: title,
                items: items,
                seriesResume: seriesResume,
                onPlayLive: playChannel,
                onRemove: onRemove,
                onStartMultiView: startMultiView,
                animationNamespace: animationNamespace
            )
        }
    }

    /// Identity of the trending/hero load, and the key its session memo is
    /// stored under. Includes the visibility token so hiding a category in
    /// Content Management reloads the rows instead of replaying a cached list
    /// that was matched against the whole catalog.
    var trendingKey: String {
        let scope = catalogScope
        let synced = playlists.members(of: scope)
            .compactMap { $0.lastSyncDate?.timeIntervalSince1970 }
            .max() ?? 0
        return "\(playlists.count)-\(scope.token)-\(synced)-\(restriction.visibilityToken)-\(groupDuplicateTitles)"
    }

    /// What the watchlist rows are matched against. Each service caches per
    /// connection state plus this scope (see `loadWatchlist`).
    var watchlistScope: String {
        "\(catalogScope.token)-\(restriction.visibilityToken)-\(groupDuplicateTitles)"
    }

    var watchlistsKey: String {
        "watchlists-\(trakt.isConnected)-\(simkl.isConnected)-\(mdblist.isConnected)-\(watchlistScope)"
    }

    /// Identity of the series resume lookup. Resuming or finishing an episode
    /// stamps its series' `lastWatchedDate` (`WatchProgressWriter`), which is
    /// exactly what the Recently Watched query orders by — so the newest stamp
    /// moves whenever a resume bar would.
    private var seriesResumeKey: String {
        let newest = watchedSeries.first?.lastWatchedDate?.timeIntervalSince1970 ?? 0
        return "resume-\(watchedSeries.count)-\(newest)-\(catalogScope.token)"
    }

    // MARK: - Playlist scoping

    /// Scopes the all-playlist `@Query` results in-memory by prefixed id, per
    /// content type: a Combined member contributes only the types switched on
    /// for it. Memoized so a body pass doesn't rebuild the prefixes per row.
    var scopeMatcher: CatalogScope.Matcher {
        scopeMatcherMemo.matcher(for: catalogScope)
    }

    // MARK: - Derived content

    private var recentlyWatched: [HomeMediaItem] {
        let scope = scopeMatcher
        var items = watchedMovies.filter { scope.contains($0.id, .movies) }.excludingRestricted(restriction).map(HomeMediaItem.movie)
            + watchedSeries.filter { scope.contains($0.id, .series) }.excludingRestricted(restriction).map(HomeMediaItem.series)
        if recentlyWatchedIncludesLiveTV {
            items += watchedStreams.filter { scope.contains($0.id, .liveTV) }.excludingRestricted(restriction).map(HomeMediaItem.live)
        }
        let newestFirst = items.sorted { ($0.lastWatchedDate ?? .distantPast) > ($1.lastWatchedDate ?? .distantPast) }
        // The newest copy stands for its title: Continue Watching reopens the
        // exact source last played.
        return Array(TitleGrouping.firstPerTitle(newestFirst, grouped: groupDuplicateTitles) { $0.titleGroupID }.prefix(10))
    }

    private var favorites: [HomeMediaItem] {
        let scope = scopeMatcher
        let ranking = titleRanking
        let movies = TitleGrouping.dedupe(
            favoriteMovies.filter { scope.contains($0.id, .movies) }.excludingRestricted(restriction),
            ranking: ranking,
            grouped: groupDuplicateTitles
        ).prefix(Self.favoritesPerKind)
        let series = TitleGrouping.dedupe(
            favoriteSeries.filter { scope.contains($0.id, .series) }.excludingRestricted(restriction),
            ranking: ranking,
            grouped: groupDuplicateTitles
        ).prefix(Self.favoritesPerKind)
        let streams = favoriteStreams.filter { scope.contains($0.id, .liveTV) }.excludingRestricted(restriction)
        typealias Entry = FavoritesOrder.Entry<HomeMediaItem>
        return FavoritesOrder.sorted(
            streams.map { Entry(order: $0.favoriteOrder, member: scope.memberRank(of: $0.id), kind: 0, num: $0.num, name: $0.name, item: .live($0)) }
                + movies.map { Entry(order: $0.favoriteOrder, member: scope.memberRank(of: $0.id), kind: 1, num: $0.num, name: $0.name, item: .movie($0)) }
                + series.map { Entry(order: $0.favoriteOrder, member: scope.memberRank(of: $0.id), kind: 2, num: $0.num, name: $0.name, item: .series($0)) }
        )
    }

    /// Truly empty home — only show the empty state once trending has settled
    /// so async-loaded content doesn't make the empty view flash on launch.
    private var isEmpty: Bool {
        recentlyWatched.isEmpty
            && favorites.isEmpty
            && trendingMovies.isEmpty
            && trendingSeries.isEmpty
            && watchlists.values.allSatisfy(\.isEmpty)
            && !sportsRailHasContent
            && trendingState.isSettled
    }

    /// Which copy of a title Home shows: the highest-priority playlist's, then
    /// the best quality and language.
    var titleRanking: TitleGrouping.Ranking {
        TitleGrouping.Ranking(
            matcher: scopeMatcher,
            preferredLanguages: preferredLanguages
        )
    }

    /// What decides `groupStateRequest` and its answer. The arrays compare by
    /// row identity; the watch dates catch new progress on an already-listed
    /// row.
    private var groupStateKey: GroupStateKey {
        GroupStateKey(
            watchedMovies: watchedMovies,
            watchedSeries: watchedSeries,
            favoriteMovies: favoriteMovies,
            favoriteSeries: favoriteSeries,
            recommendations: recommendations,
            trendingMovies: trendingMovies,
            trendingSeries: trendingSeries,
            heroItems: heroItems,
            watchlists: watchlists,
            newestMovie: watchedMovies.first?.lastWatchedDate,
            newestSeries: watchedSeries.first?.lastWatchedDate,
            scope: catalogScope,
            restriction: restriction,
            grouped: groupDuplicateTitles,
            includesLiveTV: recentlyWatchedIncludesLiveTV,
            preferredLanguages: preferredLanguages
        )
    }

    /// Every movie and series on Home, for the one grouped-state lookup.
    private var groupStateRequest: TitleGroupStates.Request {
        var request = TitleGroupStates.Request()
        request.add(recentlyWatched)
        request.add(favorites)
        request.add(recommendations)
        request.add(trendingMovies)
        request.add(trendingSeries)
        request.add(heroItems.map(\.homeItem))
        for items in watchlists.values {
            request.add(items)
        }
        return request
    }

    // MARK: - Recently watched

    /// Clears an item's watch timestamp so it drops out of the Recently Watched
    /// row. The @Query-backed rows update automatically once the change is saved.
    private func removeFromRecentlyWatched(_ item: HomeMediaItem) {
        switch item {
        case let .movie(movie):
            TitleGroupSiblings.clearLastWatched(movie, grouped: groupDuplicateTitles, in: modelContext)
        case let .series(series):
            TitleGroupSiblings.clearLastWatched(series, grouped: groupDuplicateTitles, in: modelContext)
        case let .live(stream):
            stream.lastWatchedDate = nil
        }
        try? modelContext.save()
    }

    // MARK: - Series resume

    /// Resolves the resume bar for every partially-watched series in one indexed
    /// fetch, off the main thread. The rails then read a plain dictionary rather
    /// than each card faulting its series' whole `episodes` relationship from
    /// `body` — the same hoist the Live TV list does for now/next EPG.
    private func loadSeriesResume() async {
        let container = modelContext.container
        seriesResume = await Task.detached(priority: .userInitiated) {
            SeriesResumeLoader.load(container: container)
        }.value
    }

    // MARK: - Playback

    /// Opens Multi-View seeded with a channel from one of the rails, or the
    /// paywall when the viewer isn't on Lume Pro. Mirrors `LiveTVView`'s pair of
    /// the same name — the rails are a second entry point to the same feature.
    private func startMultiView(with stream: LiveStream) {
        guard let media = PlayableMedia.from(stream: stream, ownedByOneOf: playlists) else { return }
        guard premium.isPremium else {
            showingPaywall = true
            return
        }
        #if os(macOS)
            // The window is a singleton, so it cannot be built around a launch:
            // hand the channel over and let the grid adopt it on appear.
            MultiViewLaunchQueue.shared.pending = [media]
            openWindow(id: "multiview")
        #elseif os(tvOS)
            // Presented by `MainTabView`, above the tab bar — see the router.
            router.multiViewLaunch = MultiViewLaunch(seed: [media])
        #else
            multiViewLaunch = MultiViewLaunch(seed: [media])
        #endif
    }

    private func playChannel(_ stream: LiveStream) {
        guard let media = PlayableMedia.from(
            stream: stream, ownedByOneOf: playlists, surfScope: LiveSurfScope(catalogScope)
        ) else { return }
        if ExternalPlayback.open(media) { return }
        #if os(macOS)
            MacPlayerWindowRouter.shared.play(media, using: openWindow)
        #else
            playingMedia = media
        #endif
    }
}

private struct GroupStateKey: Equatable {
    let watchedMovies: [Movie]
    let watchedSeries: [Series]
    let favoriteMovies: [Movie]
    let favoriteSeries: [Series]
    let recommendations: [HomeMediaItem]
    let trendingMovies: [HomeMediaItem]
    let trendingSeries: [HomeMediaItem]
    let heroItems: [HeroItem]
    let watchlists: [HomeWatchlistSource: [HomeMediaItem]]
    let newestMovie: Date?
    let newestSeries: Date?
    let scope: CatalogScope
    let restriction: ContentRestriction
    let grouped: Bool
    let includesLiveTV: Bool
    let preferredLanguages: [String]
}

#Preview("Empty") {
    HomeView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    HomeView()
        .modelContainer(previewContainer())
}

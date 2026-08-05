//
//  HomeView.swift
//  Lume
//
//  Default landing screen. Shows Recently Watched, Favorites, For You (opt-in
//  Pro recommendations), Trending Movies/Series and the Trakt watchlist. Which
//  rows appear and their order are user-configurable (Settings › Layout › Home,
//  see HomeLayoutSettings); each row only renders when it has content.
//

import SwiftData
import SwiftUI

struct HomeView: View {
    @Namespace private var animationNamespace
    // Several members below are `internal` (not `private`) so the trending /
    // watchlist loading in `HomeView+Trending.swift` can drive them.
    @Environment(\.modelContext) var modelContext
    @Environment(\.contentRestriction) var restriction
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    @Query private var playlists: [Playlist]
    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @AppStorage(SortStorageKey.movieCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue
    @AppStorage(SortStorageKey.movieContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue

    // Recently watched (capped — watch history is naturally bounded).
    @Query private var watchedMovies: [Movie]
    @Query private var watchedSeries: [Series]
    @Query private var watchedStreams: [LiveStream]

    // Favorites.
    @Query private var favoriteMovies: [Movie]
    @Query private var favoriteSeries: [Series]
    @Query private var favoriteStreams: [LiveStream]

    @State var trendingMovies: [HomeMediaItem] = []
    @State var trendingSeries: [HomeMediaItem] = []
    @State var watchlist: [HomeMediaItem] = []
    @AppStorage(RecommendationSettings.enabledKey) private var recommendationsEnabled = RecommendationSettings.enabledDefault
    /// The user's chosen Home row order (Settings › Layout › Home). Falls back to
    /// the declaration order of `HomeSection` until they reorder.
    @AppStorage(HomeLayoutSettings.sectionOrderKey) private var sectionOrderRaw = ""
    /// Sections the user switched off (Settings › Layout › Home). "For You" is
    /// gated by `recommendationsEnabled` instead — see `HomeLayoutSettings`.
    @AppStorage(HomeLayoutSettings.disabledSectionsKey) private var disabledSectionsRaw = ""
    /// Bumped by the DEBUG "Recalculate" action in Settings (always 0 otherwise);
    /// part of the task id so the row recomputes on demand.
    @AppStorage(RecommendationSettings.manualRecalculationKey) private var recommendationsRecalcToken = 0
    @State private var recommendations: [HomeMediaItem] = []
    /// False until the first recommendations pass completes, so the row can show
    /// a progress placeholder rather than an empty state on launch.
    @State private var recommendationsLoaded = false
    @State var heroItems: [HeroItem] = []
    @State var trendingState: HomeLoadState = .idle
    @State var trakt = TraktService.shared
    /// "For You" is a Lume Pro feature; observed so the row appears/disappears
    /// when entitlement changes.
    @State private var premium = PremiumManager.shared
    // Observed so the For You row defers its (potentially heavy) recompute while
    // the device is busy syncing — and retries automatically once it isn't.
    @State private var indexing = ContentIndexingService.shared
    @State private var epgSync = EPGSyncService.shared
    @State private var playingMedia: PlayableMedia?
    @State private var showingSync = false
    @State private var showingSettings = false

    #if os(tvOS)
        /// Hero selected on the immersive home. Drives navigation
        /// programmatically: the hero surface is a stable Button (not a
        /// NavigationLink) so paging the carousel never changes its identity.
        @State private var selectedHero: HeroItem?
    #endif

    init() {
        // Recently watched: non-nil lastWatchedDate, newest first.
        var movies = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.lastWatchedDate != nil },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        movies.fetchLimit = 20
        _watchedMovies = Query(movies)

        var series = FetchDescriptor<Series>(
            predicate: #Predicate { $0.lastWatchedDate != nil },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        series.fetchLimit = 20
        _watchedSeries = Query(series)

        var streams = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.lastWatchedDate != nil },
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
        favMovies.fetchLimit = 30
        _favoriteMovies = Query(favMovies)

        var favSeries = FetchDescriptor<Series>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name)]
        )
        favSeries.fetchLimit = 30
        _favoriteSeries = Query(favSeries)

        var favStreams = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name)]
        )
        favStreams.fetchLimit = 30
        _favoriteStreams = Query(favStreams)
    }

    var body: some View {
        NavigationStack {
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
                    #else
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 28) {
                                if !heroItems.isEmpty {
                                    HomeHeroCarousel(items: heroItems)
                                }
                                homeRows
                            }
                            .padding(.bottom)
                        }
                        .scrollIndicators(.hidden)
                        // Only let content run under the nav bar when the hero
                        // backdrop is there to fill it; otherwise the first row
                        // would sit hidden behind the bar.
                        .ignoresSafeArea(edges: heroItems.isEmpty ? [] : .top)
                    #endif
                }
            }
            .platformNavigationTitle("Home")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(heroItems.isEmpty ? .automatic : .hidden, for: .navigationBar)
            #endif
                .profileMenuToolbar()
                .libraryToolbar(config: LibraryToolbarConfiguration(
                    playlists: playlists,
                    selectedPlaylistID: $selectedPlaylistID,
                    categorySortRaw: $categorySortRaw,
                    contentSortRaw: $contentSortRaw,
                    showingSync: $showingSync,
                    showingSettings: $showingSettings,
                    activePlaylist: activePlaylist
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
            #if os(tvOS)
                .navigationDestination(item: $selectedHero) { hero in
                    if let movie = hero.movie {
                        MovieDetailView(movie: movie, animationNamespace: animationNamespace)
                    } else if let series = hero.series {
                        SeriesDetailView(series: series, animationNamespace: animationNamespace)
                    }
                }
            #endif
                .task(id: "\(playlists.count)-\(selectedPlaylistID)-\(activePlaylist?.lastSyncDate?.timeIntervalSince1970 ?? 0)") {
                    await loadTrending(cacheKey: "\(playlists.count)-\(selectedPlaylistID)-\(activePlaylist?.lastSyncDate?.timeIntervalSince1970 ?? 0)")
                }
                .task(id: "watchlist-\(trakt.isConnected)-\(selectedPlaylistID)") {
                    await loadWatchlist(cacheKey: "watchlist-\(trakt.isConnected)-\(selectedPlaylistID)")
                }
                .task(id: recommendationsKey) {
                    await loadRecommendations()
                }
            #if os(iOS) || os(tvOS)
                .fullScreenCover(item: $playingMedia) { media in
                    FullScreenPlayerView(media: media)
                }
            #endif
        }
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
                    isLoading: !recommendationsLoaded,
                    onPlayLive: playChannel,
                    onVote: vote,
                    animationNamespace: animationNamespace
                )
            case .trendingMovies:
                rail("Trending Movies", trendingMovies)
            case .trendingSeries:
                rail("Trending Series", trendingSeries)
            case .traktWatchlist:
                rail("From Your Trakt Watchlist", watchlist)
            }
        }
    }

    /// Whether `section` should render. "For You" follows the recommendations
    /// opt-in (which also gates its recompute); the rest follow the user's
    /// per-section switches.
    private func isSectionEnabled(_ section: HomeSection) -> Bool {
        section == .forYou
            ? (recommendationsEnabled && premium.isPremium)
            : HomeLayoutSettings.isEnabled(section, disabledRaw: disabledSectionsRaw)
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
            HomeRow(title: title, items: items, onPlayLive: playChannel, onRemove: onRemove, animationNamespace: animationNamespace)
        }
    }

    // MARK: - Playlist scoping

    /// The playlist whose content is currently shown, resolved from the global
    /// selection. Falls back to the first playlist until the user picks one.
    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    /// The id prefix every Movie/Series/LiveStream belonging to the active
    /// playlist shares (ids are stored as `"\(playlistID)-…"`). The `@Query`
    /// results span all playlists, so this scopes them in-memory.
    private var playlistPrefix: String? {
        activePlaylist.map { "\($0.id.uuidString)-" }
    }

    func belongsToActivePlaylist(_ id: String) -> Bool {
        guard let prefix = playlistPrefix else { return true }
        return id.hasPrefix(prefix)
    }

    // MARK: - Derived content

    private var recentlyWatched: [HomeMediaItem] {
        let items = watchedMovies.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction).map(HomeMediaItem.movie)
            + watchedSeries.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction).map(HomeMediaItem.series)
            + watchedStreams.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction).map(HomeMediaItem.live)
        return items
            .sorted { ($0.lastWatchedDate ?? .distantPast) > ($1.lastWatchedDate ?? .distantPast) }
            .prefix(10)
            .map(\.self)
    }

    private var favorites: [HomeMediaItem] {
        let movies = favoriteMovies.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction)
        let series = favoriteSeries.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction)
        let streams = favoriteStreams.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction)

        // Interleave the three types by the cross-type `favoriteOrder` set in
        // Content Management → Favorites, so a movie placed above a channel shows
        // above it here too. Items never reordered (nil) fall back to a stable
        // type/name grouping (channels, movies, then series) — the same fallback
        // the favorites manager uses.
        let entries: [(order: Int?, rank: Int, name: String, item: HomeMediaItem)] =
            streams.map { ($0.favoriteOrder, 0, $0.name, HomeMediaItem.live($0)) }
                + movies.map { ($0.favoriteOrder, 1, $0.name, HomeMediaItem.movie($0)) }
                + series.map { ($0.favoriteOrder, 2, $0.name, HomeMediaItem.series($0)) }

        return entries
            .sorted { ($0.order ?? Int.max, $0.rank, $0.name) < ($1.order ?? Int.max, $1.rank, $1.name) }
            .map(\.item)
    }

    /// Truly empty home — only show the empty state once trending has settled
    /// so async-loaded content doesn't make the empty view flash on launch.
    private var isEmpty: Bool {
        recentlyWatched.isEmpty
            && favorites.isEmpty
            && trendingMovies.isEmpty
            && trendingSeries.isEmpty
            && watchlist.isEmpty
            && trendingState.isSettled
    }

    // MARK: - Recently watched

    /// Clears an item's watch timestamp so it drops out of the Recently Watched
    /// row. The @Query-backed rows update automatically once the change is saved.
    private func removeFromRecentlyWatched(_ item: HomeMediaItem) {
        switch item {
        case let .movie(movie): movie.lastWatchedDate = nil
        case let .series(series): series.lastWatchedDate = nil
        case let .live(stream): stream.lastWatchedDate = nil
        }
        try? modelContext.save()
    }

    // MARK: - Playback

    private func playChannel(_ stream: LiveStream) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist) else { return }
        if ExternalPlayback.open(media) { return }
        #if os(macOS)
            openWindow(id: "player", value: media)
        #else
            playingMedia = media
        #endif
    }
}

// MARK: - For You

private extension HomeView {
    /// Refresh the row when the active playlist or the favorites/history queries
    /// change. This only re-resolves the list (cheap, and re-validates each entry
    /// against live state) — the engine still throttles the actual re-ranking to
    /// its recalculation interval.
    var recommendationsKey: String {
        let counts = "\(watchedMovies.count)-\(watchedSeries.count)-\(favoriteMovies.count)-\(favoriteSeries.count)"
        return "rec-\(recommendationsEnabled)-\(premium.isPremium)-\(isSyncBusy)-\(recommendationsRecalcToken)-\(counts)-\(selectedPlaylistID)"
    }

    /// True while a playlist sync, iCloud sync or EPG import is running. The For
    /// You recompute reads and ranks the whole catalog, so on older devices it's
    /// deferred until those finish — and during a CloudKit import, touching the
    /// catalog mid-handshake is best avoided entirely. Folded into
    /// `recommendationsKey` so the load retries the moment syncing settles.
    var isSyncBusy: Bool {
        playlists.contains { $0.syncStatus == .syncing }
            || indexing.isCloudSyncActive
            || epgSync.isSyncing
    }

    /// Resolves the engine's (throttled, possibly cached) list to local models,
    /// dropping any that are no longer recommendable — watched, favorited or
    /// voted on since the list was computed. That live re-validation is what lets
    /// a vote remove a card without forcing a full re-rank.
    func loadRecommendations() async {
        guard recommendationsEnabled, premium.isPremium else {
            recommendations = []
            return
        }
        // Don't calculate while syncing — leave whatever is already shown (or the
        // loading placeholder) in place; the task re-fires once `isSyncBusy` clears.
        guard !isSyncBusy else { return }

        let interval = Perf.begin(.homeRecommendations)
        defer { Perf.end(interval) }

        let engine = RecommendationEngine(modelContainer: modelContext.container)
        let scored = await engine.recommendations()
        var items: [HomeMediaItem] = []
        for recommendation in scored {
            switch recommendation.kind {
            case .movie:
                if let movie = fetchMovie(id: recommendation.id), isRecommendable(movie) { items.append(.movie(movie)) }
            case .series:
                if let series = fetchSeries(id: recommendation.id), isRecommendable(series) { items.append(.series(series)) }
            }
            if items.count >= 10 { break }
        }
        recommendations = items
        recommendationsLoaded = true
    }

    func isRecommendable(_ movie: Movie) -> Bool {
        !movie.isWatched && !movie.isFavorite && movie.lastWatchedDate == nil && movie.recommendationVote == nil
    }

    func isRecommendable(_ series: Series) -> Bool {
        !series.isFavorite && series.lastWatchedDate == nil && series.recommendationVote == nil
    }

    func fetchMovie(id: String) -> Movie? {
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let movie = try? modelContext.fetch(descriptor).first,
              belongsToActivePlaylist(movie.id), !restriction.hides(categoryID: movie.categoryId)
        else { return nil }
        return movie
    }

    func fetchSeries(id: String) -> Series? {
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let series = try? modelContext.fetch(descriptor).first,
              belongsToActivePlaylist(series.id), !restriction.hides(categoryID: series.categoryId)
        else { return nil }
        return series
    }

    /// Records an up/down vote for a recommendation. Either vote drops the title
    /// from the row immediately (it's been acted on) and steers the next recompute
    /// — an upvote pulls the taste profile toward it, a downvote away. The vote is
    /// persisted now; the engine folds it in on its next (throttled) recompute.
    func vote(_ item: HomeMediaItem, _ vote: RecommendationVote) {
        switch item {
        case let .movie(movie): movie.recommendationVote = vote
        case let .series(series): series.recommendationVote = vote
        case .live: return
        }
        // Persisted on the catalog model like favorites/watch state; the iCloud
        // reconciler mirrors it to UserContentState so the vote syncs.
        try? modelContext.save()

        recommendations.removeAll { $0.id == item.id }
    }
}

// MARK: - Load state

/// Internal (not file-private): `HomeView+Trending.swift` drives the transitions.
enum HomeLoadState {
    case idle
    case loading
    case loaded
    case failed

    var isSettled: Bool {
        switch self {
        case .idle, .loading: false
        case .loaded, .failed: true
        }
    }
}

#Preview("Empty") {
    HomeView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    HomeView()
        .modelContainer(previewContainer())
}

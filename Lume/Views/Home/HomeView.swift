//
//  HomeView.swift
//  Lume
//
//  Default landing screen. Surfaces these rows, in order:
//    1. Recently Watched — movies, series and live TV ordered by lastWatchedDate.
//    2. Favorites — everything the user has marked as a favorite.
//    3. Trending Movies — TMDB-trending movies the user actually owns.
//    4. Trending Series — TMDB-trending series the user actually owns.
//    5. From Your Trakt Watchlist — owned titles on the connected Trakt watchlist.
//
//  Each row only renders when it has content, so a fresh library degrades
//  gracefully to a friendly empty state.
//

import SwiftData
import SwiftUI

struct HomeView: View {
    @Namespace private var animationNamespace
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
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

    @State private var trendingMovies: [HomeMediaItem] = []
    @State private var trendingSeries: [HomeMediaItem] = []
    @State private var watchlist: [HomeMediaItem] = []
    @AppStorage(RecommendationSettings.enabledKey) private var recommendationsEnabled = RecommendationSettings.enabledDefault
    @State private var recommendations: [HomeMediaItem] = []
    /// False until the first recommendations pass completes, so the row can show
    /// a progress placeholder rather than an empty state on launch.
    @State private var recommendationsLoaded = false
    @State private var heroItems: [HeroItem] = []
    @State private var trendingState: LoadState = .idle
    @State private var trakt = TraktService.shared
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

        // Favorites: alphabetical, capped.
        var favMovies = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.name)]
        )
        favMovies.fetchLimit = 30
        _favoriteMovies = Query(favMovies)

        var favSeries = FetchDescriptor<Series>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.name)]
        )
        favSeries.fetchLimit = 30
        _favoriteSeries = Query(favSeries)

        var favStreams = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.name)]
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
                    await loadTrending()
                }
                .task(id: "watchlist-\(trakt.isConnected)-\(selectedPlaylistID)") {
                    await loadWatchlist()
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
    /// immersive home. Each row only renders when it has content.
    @ViewBuilder
    private var homeRows: some View {
        if !recentlyWatched.isEmpty {
            HomeRow(title: "Recently Watched", items: recentlyWatched, onPlayLive: playChannel, onRemove: removeFromRecentlyWatched, animationNamespace: animationNamespace)
        }
        if !favorites.isEmpty {
            HomeRow(title: "Favorites", items: favorites, onPlayLive: playChannel, animationNamespace: animationNamespace)
        }
        if recommendationsEnabled {
            ForYouRow(
                items: recommendations,
                isLoading: !recommendationsLoaded,
                onPlayLive: playChannel,
                onVote: vote,
                animationNamespace: animationNamespace
            )
        }
        if !trendingMovies.isEmpty {
            HomeRow(title: "Trending Movies", items: trendingMovies, onPlayLive: playChannel, animationNamespace: animationNamespace)
        }
        if !trendingSeries.isEmpty {
            HomeRow(title: "Trending Series", items: trendingSeries, onPlayLive: playChannel, animationNamespace: animationNamespace)
        }
        if !watchlist.isEmpty {
            HomeRow(title: "From Your Trakt Watchlist", items: watchlist, onPlayLive: playChannel, animationNamespace: animationNamespace)
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

    private func belongsToActivePlaylist(_ id: String) -> Bool {
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
        favoriteMovies.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction).map(HomeMediaItem.movie)
            + favoriteSeries.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction).map(HomeMediaItem.series)
            + favoriteStreams.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction).map(HomeMediaItem.live)
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

    // MARK: - Trending

    private func loadTrending() async {
        let client = TMDBClient.shared
        guard client.isConfigured else {
            trendingState = .loaded
            return
        }
        trendingState = .loading
        do {
            async let movieTitles = client.trending(.movie)
            async let tvTitles = client.trending(.tvShow)
            let (movies, tvSeries) = try await (movieTitles, tvTitles)

            var movieItems: [HomeMediaItem] = []
            var seriesItems: [HomeMediaItem] = []
            var heroes: [HeroItem] = []
            let maxCount = max(movies.count, tvSeries.count)
            for index in 0 ..< maxCount {
                if index < movies.count {
                    let title = movies[index]
                    if let movie = fetchMovie(tmdbId: title.id) {
                        movieItems.append(.movie(movie))
                        heroes.append(.movie(
                            movie,
                            backdropURL: TMDBClient.backdropURL(title.backdropPath),
                            overview: title.overview
                        ))
                    }
                }
                if index < tvSeries.count {
                    let title = tvSeries[index]
                    if let series = fetchSeries(tmdbId: title.id) {
                        seriesItems.append(.series(series))
                        heroes.append(.series(
                            series,
                            backdropURL: TMDBClient.backdropURL(title.backdropPath),
                            overview: title.overview
                        ))
                    }
                }
            }
            trendingMovies = Array(movieItems.prefix(20))
            trendingSeries = Array(seriesItems.prefix(20))
            heroItems = Array(heroes.prefix(8))
            trendingState = .loaded
            await enrichHeroLogos()
        } catch {
            trendingState = .failed
        }
    }

    /// The TMDB trending feed carries no logo artwork, so a hero title shows
    /// only its backdrop until its full details are fetched. That fetch used to
    /// happen only on the detail screen, so logos "popped in" after visiting
    /// Details and coming back. Enrich the visible hero titles up front via the
    /// same TMDB detail path. Runs after the carousel is shown so backdrops
    /// aren't blocked.
    private func enrichHeroLogos() async {
        // Enrich on the manager's background context; the saves auto-merge back
        // so the hero models pick up their logos without a main-thread store
        // write blocking the carousel.
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        for hero in heroItems {
            switch hero {
            case let .movie(movie, _, _):
                guard heroNeedsLogo(logoPath: movie.logoPath, enrichedAt: movie.tmdbEnrichedAt),
                      let tmdbId = movie.tmdbId
                else { continue }
                await manager.enrichMovie(id: movie.id, tmdbId: tmdbId)
            case let .series(series, _, _):
                guard heroNeedsLogo(logoPath: series.logoPath, enrichedAt: series.tmdbEnrichedAt),
                      let tmdbId = series.tmdbId
                else { continue }
                await manager.enrichSeries(id: series.id, tmdbId: tmdbId)
            }
        }
    }

    /// A hero needs a logo fetch when it has none yet and hasn't been enriched
    /// recently. The recency guard mirrors the detail screen's 14-day window so
    /// titles TMDB simply has no logo for aren't refetched on every appearance.
    private func heroNeedsLogo(logoPath: String?, enrichedAt: Date?) -> Bool {
        guard (logoPath ?? "").isEmpty else { return false }
        guard let enrichedAt else { return true }
        return Date().timeIntervalSince(enrichedAt) >= 14 * 24 * 3600
    }

    /// Loads the connected user's Trakt watchlist and keeps only the titles the
    /// user actually owns in the active playlist — matched by TMDB id, the same
    /// way the trending rows work.
    private func loadWatchlist() async {
        guard trakt.isConnected else {
            watchlist = []
            return
        }
        let items = await trakt.fetchWatchlist()
        var matched: [HomeMediaItem] = []
        for item in items {
            switch item.type {
            case "movie":
                if let tmdbID = item.movie?.ids.tmdb, let movie = fetchMovie(tmdbId: tmdbID) {
                    matched.append(.movie(movie))
                }
            case "show":
                if let tmdbID = item.show?.ids.tmdb, let series = fetchSeries(tmdbId: tmdbID) {
                    matched.append(.series(series))
                }
            default:
                break
            }
        }
        watchlist = Array(matched.prefix(20))
    }

    private func fetchMovie(tmdbId: Int) -> Movie? {
        let descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == tmdbId })
        let matches = (try? modelContext.fetch(descriptor)) ?? []
        return matches.first { belongsToActivePlaylist($0.id) && !restriction.hides(categoryID: $0.categoryId) }
    }

    private func fetchSeries(tmdbId: Int) -> Series? {
        let descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId })
        let matches = (try? modelContext.fetch(descriptor)) ?? []
        return matches.first { belongsToActivePlaylist($0.id) && !restriction.hides(categoryID: $0.categoryId) }
    }

    // MARK: - For You

    /// Refresh the row when the active playlist or the favorites/history queries
    /// change. This only re-resolves the list (cheap, and re-validates each entry
    /// against live state) — the engine still throttles the actual re-ranking to
    /// its recalculation interval.
    private var recommendationsKey: String {
        "rec-\(recommendationsEnabled)-\(watchedMovies.count)-\(watchedSeries.count)-\(favoriteMovies.count)-\(favoriteSeries.count)-\(selectedPlaylistID)"
    }

    /// Resolves the engine's (throttled, possibly cached) list to local models,
    /// dropping any that are no longer recommendable — watched, favorited or
    /// voted on since the list was computed. That live re-validation is what lets
    /// a vote remove a card without forcing a full re-rank.
    private func loadRecommendations() async {
        guard recommendationsEnabled else {
            recommendations = []
            return
        }
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

    private func isRecommendable(_ movie: Movie) -> Bool {
        !movie.isWatched && !movie.isFavorite && movie.lastWatchedDate == nil && movie.recommendationVote == nil
    }

    private func isRecommendable(_ series: Series) -> Bool {
        !series.isFavorite && series.lastWatchedDate == nil && series.recommendationVote == nil
    }

    private func fetchMovie(id: String) -> Movie? {
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let movie = try? modelContext.fetch(descriptor).first,
              belongsToActivePlaylist(movie.id), !restriction.hides(categoryID: movie.categoryId)
        else { return nil }
        return movie
    }

    private func fetchSeries(id: String) -> Series? {
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
    private func vote(_ item: HomeMediaItem, _ vote: RecommendationVote) {
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

// MARK: - Load state

private enum LoadState {
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

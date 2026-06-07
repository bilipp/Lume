//
//  HomeView.swift
//  Lume
//
//  Default landing screen. Surfaces four rows:
//    1. Recently Watched — movies, series and live TV ordered by lastWatchedDate.
//    2. Trending Movies — TMDB-trending movies the user actually owns.
//    3. Trending Series — TMDB-trending series the user actually owns.
//    4. Favorites — everything the user has marked as a favorite.
//
//  Each row only renders when it has content, so a fresh library degrades
//  gracefully to a friendly empty state.
//

import SwiftData
import SwiftUI

struct HomeView: View {
    @Namespace private var animationNamespace
    @Environment(\.modelContext) private var modelContext
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
    @State private var heroItems: [HeroItem] = []
    @State private var trendingState: LoadState = .idle
    @State private var trakt = TraktService.shared
    @State private var playingMedia: PlayableMedia?
    @State private var showingSync = false
    @State private var showingSettings = false

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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            if !heroItems.isEmpty {
                                HomeHeroCarousel(items: heroItems, onPlayMovie: playMovie)
                            }
                            if !recentlyWatched.isEmpty {
                                HomeRow(title: "Recently Watched", items: recentlyWatched, onPlayLive: playChannel, animationNamespace: animationNamespace)
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
                            if !favorites.isEmpty {
                                HomeRow(title: "Favorites", items: favorites, onPlayLive: playChannel, animationNamespace: animationNamespace)
                            }
                        }
                        .padding(.bottom)
                    }
                    .scrollIndicators(.hidden)
                    .ignoresSafeArea(edges: .top)
                }
            }
            .platformNavigationTitle("Home")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
            #endif
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
                .task(id: "\(playlists.count)-\(selectedPlaylistID)") {
                    await loadTrending()
                }
                .task(id: "watchlist-\(trakt.isConnected)-\(selectedPlaylistID)") {
                    await loadWatchlist()
                }
            #if os(iOS) || os(tvOS)
                .fullScreenCover(item: $playingMedia) { media in
                    FullScreenPlayerView(media: media)
                }
            #endif
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
        let items = watchedMovies.filter { belongsToActivePlaylist($0.id) }.map(HomeMediaItem.movie)
            + watchedSeries.filter { belongsToActivePlaylist($0.id) }.map(HomeMediaItem.series)
            + watchedStreams.filter { belongsToActivePlaylist($0.id) }.map(HomeMediaItem.live)
        return items
            .sorted { ($0.lastWatchedDate ?? .distantPast) > ($1.lastWatchedDate ?? .distantPast) }
            .prefix(10)
            .map(\.self)
    }

    private var favorites: [HomeMediaItem] {
        favoriteMovies.filter { belongsToActivePlaylist($0.id) }.map(HomeMediaItem.movie)
            + favoriteSeries.filter { belongsToActivePlaylist($0.id) }.map(HomeMediaItem.series)
            + favoriteStreams.filter { belongsToActivePlaylist($0.id) }.map(HomeMediaItem.live)
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
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        var didChange = false
        for hero in heroItems {
            switch hero {
            case let .movie(movie, _, _):
                guard heroNeedsLogo(logoPath: movie.logoPath, enrichedAt: movie.tmdbEnrichedAt),
                      let tmdbId = movie.tmdbId,
                      let details = try? await manager.fetchTMDBMovieDetails(tmdbId: tmdbId)
                else { continue }
                applyMovieDetails(details, to: movie, context: modelContext)
                didChange = true
            case let .series(series, _, _):
                guard heroNeedsLogo(logoPath: series.logoPath, enrichedAt: series.tmdbEnrichedAt),
                      let tmdbId = series.tmdbId,
                      let details = try? await manager.fetchTMDBTVDetails(tmdbId: tmdbId)
                else { continue }
                applySeriesDetails(details, to: series, context: modelContext)
                didChange = true
            }
        }
        if didChange { try? modelContext.save() }
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
        return matches.first { belongsToActivePlaylist($0.id) }
    }

    private func fetchSeries(tmdbId: Int) -> Series? {
        let descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId })
        let matches = (try? modelContext.fetch(descriptor)) ?? []
        return matches.first { belongsToActivePlaylist($0.id) }
    }

    // MARK: - Playback

    private func playChannel(_ stream: LiveStream) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist) else { return }
        #if os(macOS)
            openWindow(id: "player", value: media)
        #else
            playingMedia = media
        #endif
    }

    private func playMovie(_ movie: Movie) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(movie: movie, playlist: playlist) else { return }
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

// MARK: - Mixed media item

/// A type-erased wrapper over the three playable content kinds so a single
/// horizontal row can present movies, series and live channels together.
enum HomeMediaItem: Identifiable, Hashable {
    case movie(Movie)
    case series(Series)
    case live(LiveStream)

    var id: String {
        switch self {
        case let .movie(movie): "movie-\(movie.id)"
        case let .series(series): "series-\(series.id)"
        case let .live(stream): "live-\(stream.id)"
        }
    }

    var title: String {
        switch self {
        case let .movie(movie): movie.name
        case let .series(series): series.name
        case let .live(stream): stream.name
        }
    }

    var imageURL: URL? {
        switch self {
        case let .movie(movie): URL(string: movie.streamIcon ?? "")
        case let .series(series): URL(string: series.cover ?? "")
        case let .live(stream): URL(string: stream.streamIcon ?? "")
        }
    }

    var lastWatchedDate: Date? {
        switch self {
        case let .movie(movie): movie.lastWatchedDate
        case let .series(series): series.lastWatchedDate
        case let .live(stream): stream.lastWatchedDate
        }
    }

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    /// Resume fraction for partially-watched movies or series (0...1), otherwise nil.
    var progress: Double? {
        switch self {
        case let .movie(movie):
            guard let duration = movie.durationSecs, duration > 0,
                  movie.watchProgress > 0, !movie.isWatched else { return nil }
            return min(movie.watchProgress / Double(duration), 1)
        case let .series(series):
            let inProgressEpisodes = series.episodes
                .filter { $0.watchProgress > 0 && !$0.isWatched }
                .sorted { ($0.lastWatchedDate ?? .distantPast) > ($1.lastWatchedDate ?? .distantPast) }
            guard let activeEpisode = inProgressEpisodes.first,
                  let duration = activeEpisode.durationSecs, duration > 0 else { return nil }
            return min(activeEpisode.watchProgress / Double(duration), 1)
        case .live:
            return nil
        }
    }
}

// MARK: - Row

private struct HomeRow: View {
    let title: LocalizedStringKey
    let items: [HomeMediaItem]
    let onPlayLive: (LiveStream) -> Void
    var animationNamespace: Namespace.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PosterCardMetrics.railSpacing) {
                    ForEach(items) { item in
                        HomeItemCell(item: item, onPlayLive: onPlayLive, animationNamespace: animationNamespace)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, PosterCardMetrics.railVerticalPadding)
            }
            .scrollClipDisabled()
            .frame(height: PosterCardMetrics.rowHeight)
        }
    }
}

private struct HomeItemCell: View {
    let item: HomeMediaItem
    let onPlayLive: (LiveStream) -> Void
    var animationNamespace: Namespace.ID?

    var body: some View {
        switch item {
        case let .movie(movie):
            NavigationLink(value: movie) {
                HomePosterCard(title: item.title, imageURL: item.imageURL, progress: item.progress)
                    .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
            }
            .posterCardButtonStyle()
        case let .series(series):
            NavigationLink(value: series) {
                HomePosterCard(title: item.title, imageURL: item.imageURL, progress: item.progress)
                    .matchedTransitionSourceIfAvailable(id: series.id, in: animationNamespace)
            }
            .posterCardButtonStyle()
        case let .live(stream):
            Button {
                onPlayLive(stream)
            } label: {
                HomePosterCard(title: item.title, imageURL: item.imageURL, isLive: true)
            }
            .posterCardButtonStyle()
        }
    }
}

// MARK: - Poster card

/// A poster-style card used across all home rows. Shows artwork with an
/// optional resume progress bar and a "Live" badge.
private struct HomePosterCard: View {
    let title: String
    let imageURL: URL?
    var progress: Double?
    var isLive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: PosterCardMetrics.titleSpacing) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: imageURL, maxPixelSize: PosterCardMetrics.posterHeight) { phase in
                    switch phase {
                    case .empty:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay { ProgressView() }
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: isLive ? .fit : .fill)
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay {
                                Image(systemName: isLive ? "antenna.radiowaves.left.and.right" : "film")
                                    .foregroundStyle(.secondary)
                                    .font(.largeTitle)
                            }
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: PosterCardMetrics.posterWidth, height: PosterCardMetrics.posterHeight)

                if isLive {
                    Text("LIVE")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .padding(6)
                }

                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }
            }
            .frame(width: PosterCardMetrics.posterWidth, height: PosterCardMetrics.posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius))
            .shadow(radius: 2)

            Text(title)
                .font(PosterCardMetrics.titleFont)
                .lineLimit(2)
                .frame(width: PosterCardMetrics.posterWidth, alignment: .leading)
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

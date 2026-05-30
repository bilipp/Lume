//
//  HomeView.swift
//  Lume
//
//  Default landing screen. Surfaces three rows:
//    1. Recently Watched — movies, series and live TV ordered by lastWatchedDate.
//    2. Trending — TMDB-trending titles the user actually owns (matched by tmdbId).
//    3. Favorites — everything the user has marked as a favorite.
//
//  Each row only renders when it has content, so a fresh library degrades
//  gracefully to a friendly empty state.
//

import SwiftUI
import SwiftData

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

    @State private var trending: [HomeMediaItem] = []
    @State private var heroMovies: [HeroMovie] = []
    @State private var trendingState: LoadState = .idle
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
                            if !heroMovies.isEmpty {
                                HomeHeroCarousel(movies: heroMovies, onPlay: playMovie)
                            }
                            if !recentlyWatched.isEmpty {
                                HomeRow(title: "Recently Watched", items: recentlyWatched, onPlayLive: playChannel, animationNamespace: animationNamespace)
                            }
                            if !trending.isEmpty {
                                HomeRow(title: "Trending", items: trending, onPlayLive: playChannel, animationNamespace: animationNamespace)
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
            .navigationTitle("Home")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    PlaylistSwitcher(playlists: playlists, selectedPlaylistID: $selectedPlaylistID)
                }

                ToolbarItem(placement: .automatic) {
                    SortMenu(
                        categorySortRaw: $categorySortRaw,
                        contentSortRaw: $contentSortRaw
                    )
                }

                ToolbarItem(placement: .automatic) {
                    HStack {
                        Button {
                            showingSync = true
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }

                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gear")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingSync) {
                if let activePlaylist {
                    SyncProgressView(playlist: activePlaylist, isPresented: $showingSync)
                }
            }
            .navigationDestination(for: Movie.self) { movie in
                MovieDetailView(movie: movie, animationNamespace: animationNamespace)
                    .navigationTransition(.zoom(sourceID: movie.id, in: animationNamespace))
            }
            .navigationDestination(for: Series.self) { series in
                SeriesDetailView(series: series, animationNamespace: animationNamespace)
                    .navigationTransition(.zoom(sourceID: series.id, in: animationNamespace))
            }
            .task(id: "\(playlists.count)-\(selectedPlaylistID)") {
                await loadTrending()
            }
            #if os(iOS)
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
            .prefix(20)
            .map { $0 }
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
            && trending.isEmpty
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
            async let tvIDs = client.trendingIDs(.tv)
            let (movies, tv) = try await (movieTitles, tvIDs)

            var items: [HomeMediaItem] = []
            var heroes: [HeroMovie] = []
            for title in movies {
                if let movie = fetchMovie(tmdbId: title.id) {
                    items.append(.movie(movie))
                    heroes.append(HeroMovie(
                        movie: movie,
                        backdropURL: TMDBClient.backdropURL(title.backdropPath),
                        overview: title.overview
                    ))
                }
            }
            for id in tv {
                if let series = fetchSeries(tmdbId: id) {
                    items.append(.series(series))
                }
            }
            trending = Array(items.prefix(20))
            heroMovies = Array(heroes.prefix(6))
            trendingState = .loaded
        } catch {
            trendingState = .failed
        }
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
        case .idle, .loading: return false
        case .loaded, .failed: return true
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
        case .movie(let movie): return "movie-\(movie.id)"
        case .series(let series): return "series-\(series.id)"
        case .live(let stream): return "live-\(stream.id)"
        }
    }

    var title: String {
        switch self {
        case .movie(let movie): return movie.name
        case .series(let series): return series.name
        case .live(let stream): return stream.name
        }
    }

    var imageURL: URL? {
        switch self {
        case .movie(let movie): return URL(string: movie.streamIcon ?? "")
        case .series(let series): return URL(string: series.cover ?? "")
        case .live(let stream): return URL(string: stream.streamIcon ?? "")
        }
    }

    var lastWatchedDate: Date? {
        switch self {
        case .movie(let movie): return movie.lastWatchedDate
        case .series(let series): return series.lastWatchedDate
        case .live(let stream): return stream.lastWatchedDate
        }
    }

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    /// Resume fraction for partially-watched movies (0...1), otherwise nil.
    var progress: Double? {
        guard case .movie(let movie) = self,
              let duration = movie.durationSecs, duration > 0,
              movie.watchProgress > 0, !movie.isWatched else { return nil }
        return min(movie.watchProgress / Double(duration), 1)
    }
}

// MARK: - Row

private struct HomeRow: View {
    let title: String
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
                LazyHStack(spacing: 16) {
                    ForEach(items) { item in
                        HomeItemCell(item: item, onPlayLive: onPlayLive, animationNamespace: animationNamespace)
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 220)
        }
    }
}

private struct HomeItemCell: View {
    let item: HomeMediaItem
    let onPlayLive: (LiveStream) -> Void
    var animationNamespace: Namespace.ID?

    var body: some View {
        switch item {
        case .movie(let movie):
            NavigationLink(value: movie) {
                HomePosterCard(title: item.title, imageURL: item.imageURL, progress: item.progress)
                    .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
            }
            .buttonStyle(.plain)
        case .series(let series):
            NavigationLink(value: series) {
                HomePosterCard(title: item.title, imageURL: item.imageURL)
                    .matchedTransitionSourceIfAvailable(id: series.id, in: animationNamespace)
            }
            .buttonStyle(.plain)
        case .live(let stream):
            Button {
                onPlayLive(stream)
            } label: {
                HomePosterCard(title: item.title, imageURL: item.imageURL, isLive: true)
            }
            .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay { ProgressView() }
                    case .success(let image):
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
                .frame(width: 120, height: 180)

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
            .frame(width: 120, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 2)

            Text(title)
                .font(.caption)
                .lineLimit(2)
                .frame(width: 120, alignment: .leading)
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

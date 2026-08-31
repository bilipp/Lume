//
//  SearchView.swift
//  Lume
//
//  Global search across all content
//

import SwiftData
import SwiftUI

struct SearchView: View {
    @Namespace private var animationNamespace
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Query private var playlists: [Playlist]

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @AppStorage(SearchSettings.searchAllPlaylistsKey)
    private var searchAllPlaylists = SearchSettings.searchAllPlaylistsDefault
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedFilter: ContentFilter = .all
    @State private var results: [SearchResult] = []
    @State private var playingMedia: PlayableMedia?

    /// Max matches fetched per content type. Keeps the result set bounded so the
    /// list stays responsive even when a playlist holds tens of thousands of items.
    private let resultLimit = 50

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty {
                    ContentUnavailableView(
                        "Search",
                        systemImage: "magnifyingglass",
                        description: Text("Search for movies, series, or live TV channels")
                    )
                } else {
                    // Filter Picker
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(ContentFilter.allCases) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                    // Results — only show "No Results" once a query has actually
                    // been run, so it doesn't flash while the input is debouncing.
                    if results.isEmpty {
                        if !debouncedSearchText.isEmpty {
                            ContentUnavailableView.search
                        }
                    } else {
                        Section {
                            ForEach(results) { result in
                                switch result {
                                case let .movie(movie):
                                    NavigationLink(value: movie) {
                                        SearchResultRow(result: result)
                                            .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
                                    }
                                    .mediaFavoriteMenu(
                                        isFavorite: { movie.isFavorite },
                                        onToggleFavorite: { MediaFavorites.toggle(movie, in: modelContext) }
                                    )
                                case let .series(series):
                                    NavigationLink(value: series) {
                                        SearchResultRow(result: result)
                                            .matchedTransitionSourceIfAvailable(id: series.id, in: animationNamespace)
                                    }
                                    .mediaFavoriteMenu(
                                        isFavorite: { series.isFavorite },
                                        onToggleFavorite: { MediaFavorites.toggle(series, in: modelContext) }
                                    )
                                case let .liveStream(stream):
                                    Button {
                                        playChannel(stream)
                                    } label: {
                                        SearchResultRow(result: result)
                                    }
                                    .buttonStyle(.plain)
                                    .liveChannelMenu(
                                        isFavorite: stream.isFavorite,
                                        onToggleFavorite: { LiveChannelFavorites.toggle(stream, in: modelContext) }
                                    )
                                }
                            }
                        } header: {
                            Text("\(results.count) Results")
                        }
                    }
                }
            }
            .platformNavigationTitle("Search")
            .searchable(text: $searchText, prompt: "Movies, Series, Live TV...")
            #if os(iOS)
                .searchToolbarMinimizeIfAvailable()
            #endif
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
                .task(id: searchText) {
                    // Debounce raw keystrokes. .task(id:) cancels the in-flight task
                    // (including this sleep) the instant searchText changes, so the
                    // fetch below only fires once typing actually pauses.
                    let trimmed = trimmedQuery
                    guard !trimmed.isEmpty else {
                        debouncedSearchText = ""
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    debouncedSearchText = trimmed
                }
                .task(id: SearchKey(text: debouncedSearchText, filter: selectedFilter, allPlaylists: searchAllPlaylists)) {
                    // Re-run whenever the settled query or the filter changes.
                    // Filter changes are instant (no debounce on the segmented control).
                    await updateResults()
                }
        }
        #if os(iOS) || os(tvOS)
        .fullScreenCover(item: $playingMedia) { media in
            FullScreenPlayerView(media: media)
        }
        #endif
    }

    // MARK: - Playback

    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

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

    // MARK: - Searching

    /// Runs the search. Locally synced content (all Xtream/m3u content and
    /// Stalker live channels) is matched with bounded, predicate-based fetches
    /// on a background context — even a bounded `LIKE '%q%'` scan can't use an
    /// index, so the fetch returns only `Sendable` identifiers that the view
    /// context hydrates by id, and the debounce keeps typing off the main
    /// thread. A Stalker portal's movies/series aren't synced, so they come
    /// from the portal's dedicated search API instead (see `searchStalker`).
    private func updateResults() async {
        let query = debouncedSearchText
        guard !query.isEmpty else {
            results = []
            return
        }

        let playlist = activePlaylist
        let filter = selectedFilter
        let wantMovies = filter == .all || filter == .movies
        let wantSeries = filter == .all || filter == .series
        let wantLive = filter == .all || filter == .liveTV

        // A Stalker portal's movies/series aren't synced locally, so they can
        // only be found through the portal's own search API. Live TV (which
        // *is* synced) and every other source type use the local predicate
        // search. Cross-playlist search still runs the local pass too, so other
        // playlists' synced content is included.
        let usePortalForVODSeries = playlist?.sourceType == .stalker && !searchAllPlaylists
        let portal = await portalSearch(query: query, playlist: playlist, wantMovies: wantMovies, wantSeries: wantSeries)
        guard !Task.isCancelled else { return }

        let localHits = await localSearch(
            query: query, playlist: playlist,
            wantMovies: wantMovies && !usePortalForVODSeries,
            wantSeries: wantSeries && !usePortalForVODSeries,
            wantLive: wantLive
        )
        guard !Task.isCancelled else { return }

        results = assembleResults(portal: portal, localHits: localHits)
    }

    /// Portal search hits (element ids) for a Stalker active playlist; empty
    /// otherwise.
    private func portalSearch(
        query: String, playlist: Playlist?, wantMovies: Bool, wantSeries: Bool
    ) async -> (movies: [String], series: [String]) {
        guard let playlist, playlist.sourceType == .stalker, wantMovies || wantSeries else { return ([], []) }
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        return await manager.searchStalker(
            query: query, playlist: playlist,
            includeMovies: wantMovies, includeSeries: wantSeries, limit: resultLimit
        )
    }

    /// Bounded local predicate search, run off the main thread.
    private func localSearch(
        query: String, playlist: Playlist?, wantMovies: Bool, wantSeries: Bool, wantLive: Bool
    ) async -> SearchHits {
        // Scope to the active playlist unless cross-playlist search is on, in
        // which case every playlist is named and each gets its own share of the
        // budget — one alphabetically-early catalog would otherwise fill all
        // `resultLimit` rows and the others would look unsearched. Every
        // category id is prefixed with its playlist's UUID (see Category.id),
        // which appears nowhere else, so matching it within categoryId limits
        // results to that playlist. Hidden/restricted categories are excluded in
        // the fetch rather than afterwards, so `resultLimit` isn't spent on rows
        // the viewer will never see.
        let request = SearchRequest(
            query: query,
            playlistIDs: searchAllPlaylists ? playlists.map(\.id.uuidString) : [playlist?.id.uuidString].compactMap { $0 },
            wantMovies: wantMovies,
            wantSeries: wantSeries,
            wantLive: wantLive,
            excludedCategoryIDs: restriction.excludedCategoryIDs,
            limit: resultLimit
        )
        let container = modelContext.container
        return await Task.detached(priority: .userInitiated) {
            SearchFetcher.fetch(container: container, request: request)
        }.value
    }

    /// Portal hits first (relevance order), then the local pass. Hydrates rows
    /// in the view context, drops any the active profile restricts, and dedupes
    /// so an already-imported title isn't listed twice.
    private func assembleResults(
        portal: (movies: [String], series: [String]), localHits: SearchHits
    ) -> [SearchResult] {
        var matches: [SearchResult] = []
        var seen = Set<String>()
        func add(_ result: SearchResult, categoryID: String?) {
            guard !restriction.hides(categoryID: categoryID), seen.insert(result.id).inserted else { return }
            matches.append(result)
        }
        for movie in hydrateMovies(ids: portal.movies) {
            add(.movie(movie), categoryID: movie.categoryId)
        }
        for series in hydrateSeries(ids: portal.series) {
            add(.series(series), categoryID: series.categoryId)
        }
        for id in localHits.movies {
            if let movie = modelContext.model(for: id) as? Movie { add(.movie(movie), categoryID: movie.categoryId) }
        }
        for id in localHits.series {
            if let series = modelContext.model(for: id) as? Series { add(.series(series), categoryID: series.categoryId) }
        }
        for id in localHits.streams {
            if let stream = modelContext.model(for: id) as? LiveStream { add(.liveStream(stream), categoryID: stream.categoryId) }
        }
        return matches
    }

    /// Fetches `Movie` rows for the given ids in one query, returned in id order.
    private func hydrateMovies(ids: [String]) -> [Movie] {
        guard !ids.isEmpty else { return [] }
        let fetched = (try? modelContext.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        let byId = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byId[$0] }
    }

    /// Fetches `Series` rows for the given ids in one query, returned in id order.
    private func hydrateSeries(ids: [String]) -> [Series] {
        guard !ids.isEmpty else { return [] }
        let fetched = (try? modelContext.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        let byId = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byId[$0] }
    }
}

// MARK: - Search Key

/// Identity for the fetch task: re-run when the settled query text, the active
/// content filter, or the cross-playlist search preference changes.
private struct SearchKey: Equatable {
    let text: String
    let filter: ContentFilter
    let allPlaylists: Bool
}

// MARK: - Search Settings

enum SearchSettings {
    /// When enabled, search spans every configured playlist. Off by default, so
    /// results stay scoped to the active playlist unless the user opts in.
    static let searchAllPlaylistsKey = "search.allPlaylists"
    static let searchAllPlaylistsDefault = false
}

// MARK: - Content Filter

enum ContentFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case movies = "Movies"
    case series = "Series"
    case liveTV = "Live TV"

    var id: String {
        rawValue
    }

    var label: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

// MARK: - Search Result

enum SearchResult: Identifiable, Hashable {
    case movie(Movie)
    case series(Series)
    case liveStream(LiveStream)

    var id: String {
        switch self {
        case let .movie(movie):
            "movie-\(movie.id)"
        case let .series(series):
            "series-\(series.id)"
        case let .liveStream(stream):
            "live-\(stream.id)"
        }
    }

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            CachedAsyncImage(url: thumbnailURL, maxPixelSize: 90) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay {
                            ProgressView()
                        }
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay {
                            Image(systemName: iconName)
                                .foregroundStyle(.secondary)
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: categoryIcon)
                    Text(LocalizedStringKey(categoryName))
                }
                .font(.caption2)
                .foregroundStyle(.blue)
            }

            Spacer()
        }
    }

    private var thumbnailURL: URL? {
        switch result {
        case let .movie(movie):
            URL(string: movie.streamIcon ?? "")
        case let .series(series):
            URL(string: series.cover ?? "")
        case let .liveStream(stream):
            URL(string: stream.streamIcon ?? "")
        }
    }

    private var title: String {
        switch result {
        case let .movie(movie):
            movie.name
        case let .series(series):
            series.name
        case let .liveStream(stream):
            stream.name
        }
    }

    private var subtitle: String {
        switch result {
        case let .movie(movie):
            movie.genre ?? movie.releaseDate ?? ""
        case let .series(series):
            series.genre ?? series.releaseDate ?? ""
        case .liveStream:
            "Live"
        }
    }

    private var categoryName: String {
        switch result {
        case .movie:
            "Movie"
        case .series:
            "Series"
        case .liveStream:
            "Live TV"
        }
    }

    private var categoryIcon: String {
        switch result {
        case .movie:
            "film"
        case .series:
            "tv"
        case .liveStream:
            "antenna.radiowaves.left.and.right"
        }
    }

    private var iconName: String {
        switch result {
        case .movie:
            "film"
        case .series:
            "tv"
        case .liveStream:
            "antenna.radiowaves.left.and.right"
        }
    }
}

#Preview("Empty") {
    SearchView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    SearchView()
        .modelContainer(previewContainer())
}

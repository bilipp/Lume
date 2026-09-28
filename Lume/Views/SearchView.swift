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

    // How long typing has to pause before a query runs. Longer on tvOS: a
    // remote enters a letter every second or so, which a short debounce turns
    // into a full search and list rebuild per letter while the keyboard is
    // still being driven.
    #if os(tvOS)
        private static let debounce: Duration = .milliseconds(700)
    #else
        private static let debounce: Duration = .milliseconds(300)
    #endif

    /// Whether the content filter is on screen. tvOS keeps it up while the
    /// query is empty too, so the first letter doesn't restructure the list
    /// under the keyboard.
    private var showsFilter: Bool {
        #if os(tvOS)
            true
        #else
            !trimmedQuery.isEmpty
        #endif
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                if showsFilter {
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(ContentFilter.allCases) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if trimmedQuery.isEmpty {
                    ContentUnavailableView(
                        "Search",
                        systemImage: "magnifyingglass",
                        description: Text("Search for movies, series, or live TV channels")
                    )
                } else {
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
                                        SearchResultRow(result: result, playlistName: playlistName(for: result))
                                            .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
                                    }
                                    .mediaFavoriteMenu(
                                        isFavorite: { movie.isFavorite },
                                        onToggleFavorite: { MediaFavorites.toggle(movie, in: modelContext) }
                                    )
                                case let .series(series):
                                    NavigationLink(value: series) {
                                        SearchResultRow(result: result, playlistName: playlistName(for: result))
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
                                        SearchResultRow(result: result, playlistName: playlistName(for: result))
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
            .searchField(text: $searchText)
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
                try? await Task.sleep(for: Self.debounce)
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

    /// The owning playlist's name, for rows that could have come from any of
    /// them. Only while searching across several playlists: with one playlist
    /// in play it's the same badge on every row, and the point of it is telling
    /// two identically-named rows from different providers apart.
    private func playlistName(for result: SearchResult) -> String? {
        guard searchAllPlaylists, playlists.count > 1 else { return nil }
        return playlists.owner(ofContentID: result.contentID)?.name
    }

    private func playChannel(_ stream: LiveStream) {
        // Cross-playlist search surfaces channels the active playlist can't
        // stream: a live URL is built from its playlist's server, credentials
        // and portal, so playing a foreign channel with the active playlist
        // asks the wrong provider for it. Stream ids are per-provider integers,
        // so that doesn't reliably fail — it can quietly play whichever channel
        // holds the same id over there.
        guard let playlist = playlists.owner(ofContentID: stream.id) ?? activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist) else { return }
        if ExternalPlayback.open(media) { return }
        #if os(macOS)
            MacPlayerWindowRouter.shared.play(media, using: openWindow)
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
        // only be found through the portal's own search API — asked of every
        // Stalker playlist in scope, not just the active one. Live TV (which
        // *is* synced) and every other source type use the local predicate
        // search. Cross-playlist search still runs the local pass too, so other
        // playlists' synced content is included.
        let usePortalForVODSeries = playlist?.sourceType == .stalker && !searchAllPlaylists
        let portal = await portalSearch(query: query, wantMovies: wantMovies, wantSeries: wantSeries)
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

    /// Portal search hits (element ids) from every Stalker playlist in scope.
    /// A Stalker catalog's movies and series are never synced into the store,
    /// so the portal's own search API is the only way to reach them — which
    /// left a non-active Stalker playlist invisible to search whatever
    /// "Search All Playlists" was set to, since the local pass has nothing of
    /// its VOD to find.
    private func portalSearch(
        query: String, wantMovies: Bool, wantSeries: Bool
    ) async -> (movies: [String], series: [String]) {
        let targets = portalPlaylists
        guard !targets.isEmpty, wantMovies || wantSeries else { return ([], []) }
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        var movies: [[String]] = []
        var series: [[String]] = []
        // One portal at a time: these are separate providers, each with its own
        // connection allowance, and a Stalker middleware is quick to refuse a
        // second session. The debounce means only a settled query gets here,
        // and cancellation stops the walk before the next portal is asked.
        for playlist in targets {
            guard !Task.isCancelled else { break }
            let hits = await manager.searchStalker(
                query: query, playlist: playlist,
                includeMovies: wantMovies, includeSeries: wantSeries, limit: resultLimit
            )
            movies.append(hits.movies)
            series.append(hits.series)
        }
        // Each portal ranks its own hits, so rotate rather than concatenate.
        return (interleaved(movies, limit: resultLimit), interleaved(series, limit: resultLimit))
    }

    /// The Stalker playlists this search asks directly: all of them while
    /// searching across playlists, otherwise the active one if it happens to
    /// be a portal.
    private var portalPlaylists: [Playlist] {
        let candidates = searchAllPlaylists ? playlists : [activePlaylist].compactMap(\.self)
        return candidates.filter { $0.sourceType == .stalker }
    }

    /// Bounded local predicate search, run off the main thread.
    private func localSearch(
        query: String, playlist: Playlist?, wantMovies: Bool, wantSeries: Bool, wantLive: Bool
    ) async -> SearchHits {
        // Scope to the active playlist unless cross-playlist search is on, in
        // which case every playlist is named and each gets its own share of the
        // budget — one catalog would otherwise fill all `resultLimit` rows and
        // the others would look unsearched. Every catalog row's id carries its
        // playlist's UUID as a prefix (see `SearchScope.playlistIDPrefix`), so a
        // prefix test on the indexed `id` limits results to that playlist.
        // Hidden/restricted categories are excluded in the fetch rather than
        // afterwards, so `resultLimit` isn't spent on rows the viewer will
        // never see.
        let scoped = searchAllPlaylists ? playlists : [playlist].compactMap(\.self)
        let request = SearchRequest(
            query: query,
            playlistIDs: scoped.map(\.id.uuidString),
            wantMovies: wantMovies,
            wantSeries: wantSeries,
            wantLive: wantLive,
            excludedCategoryIDs: restriction.excludedCategoryIDs,
            limit: resultLimit
        )
        let container = modelContext.container
        // `Task.detached` starts an unstructured task, which does not inherit
        // this one's cancellation: every keystroke that settled into a query
        // used to leave its scans running to the end, so on a large catalog the
        // superseded work piled up behind the query the viewer is waiting for.
        // Forwarding the cancellation lets `SearchFetcher` bail between its
        // scans; the partial hits it returns are dropped by
        // `updateResults`, which is the task being cancelled.
        let fetch = Task.detached(priority: .userInitiated) {
            SearchFetcher.fetch(container: container, request: request)
        }
        return await withTaskCancellationHandler {
            await fetch.value
        } onCancel: {
            fetch.cancel()
        }
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
        // The local fetches deliberately run without an ORDER BY so SQLite can
        // stop at the per-type limit instead of sorting every match first (see
        // `SearchFetcher.fetch`). The per-type, name-ascending order the list
        // has always shown is restored here, over at most `resultLimit`
        // hydrated rows per type. `localizedStandardCompare` is what
        // `SortDescriptor(\.name)` used, so the ordering is unchanged.
        for movie in sortedByName(hydrateSearchHits(localHits.movies, in: modelContext) as [Movie], name: \.name) {
            add(.movie(movie), categoryID: movie.categoryId)
        }
        for series in sortedByName(hydrateSearchHits(localHits.series, in: modelContext) as [Series], name: \.name) {
            add(.series(series), categoryID: series.categoryId)
        }
        for stream in sortedByName(hydrateSearchHits(localHits.streams, in: modelContext) as [LiveStream], name: \.name) {
            add(.liveStream(stream), categoryID: stream.categoryId)
        }
        return matches
    }

    /// Name order, by the comparator `SortDescriptor(\.name)` defaults to.
    private func sortedByName<Model>(_ models: [Model], name: KeyPath<Model, String>) -> [Model] {
        models.sorted { $0[keyPath: name].localizedStandardCompare($1[keyPath: name]) == .orderedAscending }
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

// MARK: - Search field

private extension View {
    /// The search field, pinned at the top wherever it lands in the
    /// navigation bar — iPad, the More list, and some iPhones — where it would
    /// otherwise stay hidden until the list is pulled down (iPadOS 26 even
    /// parks it as a collapsed magnifier button). Where the search tab puts
    /// the field in the tab bar instead, that placement still wins.
    func searchField(text: Binding<String>) -> some View {
        modifier(SearchFieldModifier(text: text))
    }
}

private struct SearchFieldModifier: ViewModifier {
    @Binding var text: String
    #if os(tvOS)
        @State private var fieldText = FieldText()
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
            content.searchable(text: fieldBinding, prompt: "Movies, Series, Live TV...")
        #else
            content.searchable(text: $text, placement: placement, prompt: "Movies, Series, Live TV...")
        #endif
    }

    #if os(tvOS)
        /// Text typed on the iPhone Remote keyboard appears in the field and is
        /// then deleted again, from the second letter on — the known tvOS
        /// `.searchable` fight between the remote session and SwiftUI writing
        /// its binding back into the field. The getter here answers with the
        /// text the field itself last reported, read from a plain reference
        /// rather than view state, so a write-back can never carry an older
        /// value than the one on screen.
        private var fieldBinding: Binding<String> {
            let fieldText = fieldText
            return Binding(
                get: { fieldText.value },
                set: { newValue in
                    fieldText.value = newValue
                    text = newValue
                }
            )
        }
    #endif

    private var placement: SearchFieldPlacement {
        #if os(iOS)
            .navigationBarDrawer(displayMode: .always)
        #else
            .automatic
        #endif
    }
}

#if os(tvOS)
    /// The search field's latest text. A class, and deliberately not
    /// observable: writing it must not schedule a view update of its own.
    private final class FieldText {
        var value = ""
    }
#endif

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

    /// The catalog row's own id, which carries the owning playlist's UUID as a
    /// prefix. `id` above namespaces by kind so a movie and a channel can't
    /// collide in the list; this one is what `owner(ofContentID:)` reads.
    var contentID: String {
        switch self {
        case let .movie(movie): movie.id
        case let .series(series): series.id
        case let .liveStream(stream): stream.id
        }
    }

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
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

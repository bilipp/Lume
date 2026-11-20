//
//  GenreBrowse.swift
//  Lume
//
//  "Browse by Genre" on the Movies and Series tabs. Genre cuts across the
//  provider categories — a title's genre comes from TMDB/playlist metadata, not
//  the category it lives in — so these surfaces are driven by the title's
//  `genre` string rather than a `categoryId`, mirroring the cross-category
//  library collection rows.
//

import SwiftData
import SwiftUI

// MARK: - Genre derivation

/// Upper bound on the fetch that enumerates a playlist's genres. The genre
/// vocabulary is tiny (a couple dozen names) and saturates almost immediately,
/// so a bounded sample surfaces every genre in practice while keeping the
/// derivation cheap on libraries with tens of thousands of titles — the same
/// trade-off `LibraryCollectionRows` makes for "Recently Added".
private let genreSampleLimit = 5000

enum GenreDerivation {
    /// Derives the genre list on a background context. The sample fetch hydrates
    /// up to `genreSampleLimit` rows, which ran ~500ms on the *main* thread when
    /// invoked from a view's `.task` (the closure inherits the view's MainActor
    /// isolation) — a visible hitch when opening the tab or after a sync
    /// invalidates the query. Running it off the main thread (and fetching only
    /// the three columns the derivation reads) removes the hang entirely.
    static func movieGenres(in container: ModelContainer, scope: CatalogScope, restriction: ContentRestriction) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.genre != nil })
            descriptor.fetchLimit = genreSampleLimit
            descriptor.propertiesToFetch = [\.id, \.genre, \.categoryId]
            let movies = (try? ModelContext(container).fetch(descriptor)) ?? []
            return Self.derive(scope: scope, tab: .movies, restriction: restriction, rows: movies)
        }.value
    }

    static func seriesGenres(in container: ModelContainer, scope: CatalogScope, restriction: ContentRestriction) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.genre != nil })
            descriptor.fetchLimit = genreSampleLimit
            descriptor.propertiesToFetch = [\.id, \.genre, \.categoryId]
            let series = (try? ModelContext(container).fetch(descriptor)) ?? []
            return Self.derive(scope: scope, tab: .series, restriction: restriction, rows: series)
        }.value
    }

    /// Scopes the sampled rows to the scope's contributing playlists and the
    /// viewer (the `excludingRestricted` filter, inlined so this stays
    /// `nonisolated`), then derives the distinct genres. Runs on the caller's
    /// background context.
    private nonisolated static func derive(
        scope: CatalogScope,
        tab: PlaylistTab,
        restriction: ContentRestriction,
        rows: [some GenreCarrying]
    ) -> [String] {
        guard !scope.isEmpty else { return [] }
        let matcher = CatalogScope.Matcher(scope)
        let excluded = restriction.excludedCategoryIDs
        let genres = rows.lazy
            .filter { row in matcher.contains(row.id, tab) }
            .filter { excluded.isEmpty || !excluded.contains($0.categoryId ?? "") }
            .map(\.genre)
        return GenreParser.distinctByFrequency(Array(genres))
    }
}

/// The fields the genre derivation reads off a sampled title. `nonisolated` so
/// `derive` can run on a background context (default isolation is `MainActor`);
/// the witnesses are `@Model` stored properties, which are safe to read off the
/// main thread on a background `ModelContext`. Lets `derive` work over both
/// `Movie` and `Series` without duplicating the scoping logic.
nonisolated protocol GenreCarrying {
    var id: String { get }
    var genre: String? { get }
    var categoryId: String? { get }
}

// The conformances are `nonisolated` too, not just the protocol: under
// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor a bare `extension Movie: GenreCarrying`
// declares a main-actor-isolated conformance, which cannot satisfy the
// `Sendable` requirement `scan`'s generic parameter carries.
nonisolated extension Movie: GenreCarrying {}
nonisolated extension Series: GenreCarrying {}

// MARK: - Browse-by-genre section

/// A tile grid of the genres present in the active scope, most-common first.
/// Each tile navigates to that genre's full grid.
///
/// The owning view derives the genres and renders this only when the list is
/// non-empty: a view that collapses to nothing never receives `.task`/`.onAppear`
/// (the same EmptyView lifecycle trap `CachedAsyncImage` hit), so the derivation
/// must live on an always-present host — the browse `ScrollView` — not here.
struct GenreGridSection: View {
    let genres: [String]
    let type: CategoryType

    private let columns = [GridItem(.adaptive(minimum: CategoryTileMetrics.minimum), spacing: CategoryTileMetrics.spacing)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse by Genre")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            LazyVGrid(columns: columns, spacing: CategoryTileMetrics.spacing) {
                ForEach(genres, id: \.self) { genre in
                    NavigationLink(value: GenreSelection(genre: genre, type: type)) {
                        CategoryTile(name: genre)
                    }
                    .posterCardButtonStyle()
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Genre detail grids

/// The full grid of movies in a genre, reachable from a genre tile. The fetch
/// narrows to candidate rows in SQLite with `localizedStandardContains`, then
/// re-filters to exact-token matches so substrings can't sneak in — all of it
/// on a background context (`GenrePageFetcher`), because the grid asks for the
/// next page from a cell's `onAppear`, mid-scroll.
struct MovieGenreView: View {
    let genre: String
    let scope: CatalogScope
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction

    @AppStorage(SortStorageKey.movieContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @AppStorage(LibrarySettings.groupDuplicateTitlesKey)
    private var groupDuplicateTitles = LibrarySettings.groupDuplicateTitlesDefault
    @State private var movies: [Movie] = []
    /// State of the loaded titles' other copies, looked up once per page.
    @State private var groupStates: [String: TitleGroupState] = [:]
    @State private var canLoadMore = true
    @State private var isLoadingPage = false
    /// SQLite cursor position, distinct from `movies.count`. The exact-token and
    /// visibility re-checks drop rows the substring fetch returned, so the
    /// displayed count and the source offset diverge — the offset must track
    /// rows pulled from SQLite, not rows shown.
    @State private var fetchedCount = 0
    /// Titles the loaded pages show when grouped; see `GenrePage.seenKeys`.
    @State private var seenKeys: Set<String> = []
    /// The sort the current pages were loaded for. Pushing a detail cancels and
    /// (on pop) re-runs `.task`; reloading page one there would discard the
    /// loaded pages and reset the scroll position. Reload only when this differs.
    @State private var loadedSort: String?
    /// Bumped whenever the loaded pages are thrown away. A page fetch already in
    /// flight resolves against the old cursor, so its rows have to be dropped
    /// rather than appended to the fresh list.
    @State private var loadGeneration = 0

    /// A popular genre in a large IPTV playlist can span thousands of titles;
    /// fetch a page at a time and load the next as the grid nears the end,
    /// rather than hydrating the whole genre into memory at once — mirroring
    /// `MovieCategoryView`.
    private let pageSize = 100

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    /// The sort and grouping the loaded pages were fetched for.
    private var loadKey: String {
        "\(contentSortRaw)|\(groupDuplicateTitles)"
    }

    var body: some View {
        CategoryContentGrid(
            title: genre,
            items: movies,
            animationNamespace: animationNamespace,
            emptyTitle: "No Movies",
            emptyIcon: "film.stack",
            emptyDescription: "No movies in this genre",
            sortRaw: $contentSortRaw,
            onLoadMore: { loadNextPage() },
            favoriteMenu: CategoryFavoriteMenu(
                isFavorite: { TitleGroupStateLookup.state(of: $0, in: groupStates).isFavorite },
                toggle: { toggleFavorite($0) }
            ),
            card: { movie in
                MovieCardView(movie: movie, fillsWidth: true)
            }
        )
        .environment(\.titleGroupStates, TitleGroupStates(movies: groupStates))
        .task(id: loadKey) {
            guard loadedSort != loadKey else {
                refreshGroupStates()
                return
            }
            loadedSort = loadKey
            groupStates = [:]
            // A page fetched against the previous sort's cursor is now
            // meaningless: bump the generation so it's discarded on arrival, and
            // release the in-flight guard here, since that load no longer will.
            loadGeneration += 1
            isLoadingPage = false
            movies = []
            fetchedCount = 0
            seenKeys = []
            canLoadMore = true
            loadNextPage()
        }
    }

    private func loadNextPage() {
        guard canLoadMore, !isLoadingPage else { return }
        isLoadingPage = true
        let generation = loadGeneration
        let request = GenrePageRequest(
            genre: genre,
            scope: scope,
            excludedCategoryIDs: restriction.excludedCategoryIDs,
            offset: fetchedCount,
            pageSize: pageSize,
            grouped: groupDuplicateTitles,
            seenKeys: seenKeys
        )
        let sortBy = contentSort.movieDescriptors
        let container = modelContext.container
        Task {
            let page = await Task.detached(priority: .userInitiated) {
                GenrePageFetcher.movies(container: container, request: request, sortBy: sortBy)
            }.value
            guard generation == loadGeneration else { return }
            apply(page)
        }
    }

    /// Hydrates the fetched identifiers in the view context and advances the
    /// cursor. An empty page with the source not yet exhausted means the scan
    /// budget ran out before anything displayable turned up; resume from the new
    /// offset, because the grid can't ask again — nothing new appeared for it to
    /// fire `onLoadMore` from.
    private func apply(_ page: GenrePage) {
        isLoadingPage = false
        fetchedCount += page.scanned
        seenKeys = page.seenKeys
        if page.reachedEnd { canLoadMore = false }
        let rows = page.ids.compactMap { modelContext.model(for: $0) as? Movie }
        movies.append(contentsOf: rows)
        let keys = rows.compactMap(\.titleGroupKey)
        groupStates.replace(keys: keys, with: TitleGroupStateLookup.movies(keys: keys, in: modelContext))
        if page.ids.isEmpty, canLoadMore { loadNextPage() }
    }

    private func refreshGroupStates() {
        groupStates = TitleGroupStateLookup.states(of: movies, in: modelContext)
    }

    private func toggleFavorite(_ movie: Movie) {
        TitleGroupFavorites.toggle(movie, updating: &groupStates, in: modelContext)
    }
}

/// The full grid of series in a genre; paged off the main actor exactly as
/// `MovieGenreView` is.
struct SeriesGenreView: View {
    let genre: String
    let scope: CatalogScope
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction

    @AppStorage(SortStorageKey.seriesContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @AppStorage(LibrarySettings.groupDuplicateTitlesKey)
    private var groupDuplicateTitles = LibrarySettings.groupDuplicateTitlesDefault
    @State private var series: [Series] = []
    /// State of the loaded titles' other copies, looked up once per page.
    @State private var groupStates: [String: TitleGroupState] = [:]
    @State private var canLoadMore = true
    @State private var isLoadingPage = false
    /// SQLite cursor position, distinct from `series.count` — see `MovieGenreView`.
    @State private var fetchedCount = 0
    /// Titles the loaded pages show when grouped; see `GenrePage.seenKeys`.
    @State private var seenKeys: Set<String> = []
    /// Sort the current pages were loaded for; reload only on change — see
    /// `MovieGenreView`, which explains why reappearance must not reset.
    @State private var loadedSort: String?
    /// Discards a page fetched against a cursor that has since been reset — see
    /// `MovieGenreView`.
    @State private var loadGeneration = 0

    /// Page a genre at a time rather than hydrating it whole; see `MovieGenreView`.
    private let pageSize = 100

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    /// The sort and grouping the loaded pages were fetched for.
    private var loadKey: String {
        "\(contentSortRaw)|\(groupDuplicateTitles)"
    }

    var body: some View {
        CategoryContentGrid(
            title: genre,
            items: series,
            animationNamespace: animationNamespace,
            emptyTitle: "No Series",
            emptyIcon: "tv.fill",
            emptyDescription: "No series in this genre",
            sortRaw: $contentSortRaw,
            onLoadMore: { loadNextPage() },
            favoriteMenu: CategoryFavoriteMenu(
                isFavorite: { TitleGroupStateLookup.state(of: $0, in: groupStates).isFavorite },
                toggle: { toggleFavorite($0) }
            ),
            card: { series in
                SeriesCardView(series: series, fillsWidth: true)
            }
        )
        .environment(\.titleGroupStates, TitleGroupStates(series: groupStates))
        .task(id: loadKey) {
            guard loadedSort != loadKey else {
                refreshGroupStates()
                return
            }
            loadedSort = loadKey
            groupStates = [:]
            loadGeneration += 1
            isLoadingPage = false
            series = []
            fetchedCount = 0
            seenKeys = []
            canLoadMore = true
            loadNextPage()
        }
    }

    private func loadNextPage() {
        guard canLoadMore, !isLoadingPage else { return }
        isLoadingPage = true
        let generation = loadGeneration
        let request = GenrePageRequest(
            genre: genre,
            scope: scope,
            excludedCategoryIDs: restriction.excludedCategoryIDs,
            offset: fetchedCount,
            pageSize: pageSize,
            grouped: groupDuplicateTitles,
            seenKeys: seenKeys
        )
        let sortBy = contentSort.seriesDescriptors
        let container = modelContext.container
        Task {
            let page = await Task.detached(priority: .userInitiated) {
                GenrePageFetcher.series(container: container, request: request, sortBy: sortBy)
            }.value
            guard generation == loadGeneration else { return }
            apply(page)
        }
    }

    /// Hydrates and advances the cursor, resuming when the scan budget ran out
    /// empty — see `MovieGenreView.apply`.
    private func apply(_ page: GenrePage) {
        isLoadingPage = false
        fetchedCount += page.scanned
        seenKeys = page.seenKeys
        if page.reachedEnd { canLoadMore = false }
        let rows = page.ids.compactMap { modelContext.model(for: $0) as? Series }
        series.append(contentsOf: rows)
        let keys = rows.compactMap(\.titleGroupKey)
        groupStates.replace(keys: keys, with: TitleGroupStateLookup.series(keys: keys, in: modelContext))
        if page.ids.isEmpty, canLoadMore { loadNextPage() }
    }

    private func refreshGroupStates() {
        groupStates = TitleGroupStateLookup.states(of: series, in: modelContext)
    }

    private func toggleFavorite(_ series: Series) {
        TitleGroupFavorites.toggle(series, updating: &groupStates, in: modelContext)
    }
}

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
    static func movieGenres(in container: ModelContainer, playlistPrefix: String, restriction: ContentRestriction) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.genre != nil })
            descriptor.fetchLimit = genreSampleLimit
            descriptor.propertiesToFetch = [\.id, \.genre, \.categoryId]
            let movies = (try? ModelContext(container).fetch(descriptor)) ?? []
            return Self.derive(playlistPrefix: playlistPrefix, restriction: restriction, rows: movies)
        }.value
    }

    static func seriesGenres(in container: ModelContainer, playlistPrefix: String, restriction: ContentRestriction) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.genre != nil })
            descriptor.fetchLimit = genreSampleLimit
            descriptor.propertiesToFetch = [\.id, \.genre, \.categoryId]
            let series = (try? ModelContext(container).fetch(descriptor)) ?? []
            return Self.derive(playlistPrefix: playlistPrefix, restriction: restriction, rows: series)
        }.value
    }

    /// Scopes the sampled rows to the active playlist and viewer (the
    /// `excludingRestricted` filter, inlined so this stays `nonisolated`), then
    /// derives the distinct genres. Runs on the caller's background context.
    private nonisolated static func derive(
        playlistPrefix: String,
        restriction: ContentRestriction,
        rows: [some GenreCarrying]
    ) -> [String] {
        let excluded = restriction.excludedCategoryIDs
        let genres = rows.lazy
            .filter { $0.id.hasPrefix(playlistPrefix) }
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

/// A tile grid of the genres present in the active playlist, most-common first.
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

// MARK: - Off-main genre page fetch

/// How many source rows one page load may walk before handing control back to
/// the caller. The re-checks below can empty a whole source page, and each
/// retry is another scan, so a genre whose next few hundred rows are all
/// near-misses would otherwise chain scans until it found something. Five
/// source pages is the bound; the caller resumes from the returned cursor.
private let genreScanBudget = 500

/// What one page of a genre grid is fetched for. Plain value type so the
/// off-main fetch takes a single `Sendable` value, mirroring `SearchRequest`.
nonisolated struct GenrePageRequest {
    let genre: String
    /// `"<playlistUUID>-"` — the id prefix every title in the active playlist
    /// shares, matched in SQLite rather than after materialization.
    let playlistPrefix: String
    let excludedCategoryIDs: Set<String>
    /// Where in the source rows to resume; see `GenrePage.scanned`.
    let offset: Int
    let pageSize: Int
}

/// A page's displayable rows — identifiers only, never managed objects, which
/// can't cross actor boundaries — plus the cursor state the view carries
/// forward.
nonisolated struct GenrePage {
    var ids: [PersistentIdentifier] = []
    /// Source rows consumed, which is what the next `fetchOffset` must advance
    /// by: the re-checks drop rows the substring fetch returned, so the
    /// displayed count and the source offset diverge.
    var scanned = 0
    /// The source is exhausted — no further page can exist.
    var reachedEnd = false
}

/// Runs a genre page fetch on a background `ModelContext`, mirroring
/// `SearchFetcher`.
///
/// This used to be a synchronous `fetch` on the *main* context, fired from a
/// grid cell's `onAppear` mid-scroll. `localizedStandardContains` can't use the
/// `genre` index, so every page scanned the table — hundreds of milliseconds
/// per page on a 179k-title playlist, and the retry loop could chain several of
/// those into one frame, which is a watchdog hazard rather than a hitch.
nonisolated enum GenrePageFetcher {
    static func movies(
        container: ModelContainer,
        request: GenrePageRequest,
        sortBy: [SortDescriptor<Movie>]
    ) -> GenrePage {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Movie>(predicate: moviePredicate(request: request), sortBy: sortBy)
        descriptor.fetchLimit = request.pageSize
        // Only `genre` (the exact-token re-check) and `categoryId` (viewer
        // visibility) are read off the fetched rows, so leave the rest
        // unhydrated — the same trade the genre derivation above makes, and it
        // keeps a page of wide rows (plot, cast, artwork paths) out of memory.
        descriptor.propertiesToFetch = [\.genre, \.categoryId]
        return scan(request: request) { (offset: Int) -> [Movie] in
            descriptor.fetchOffset = offset
            return (try? context.fetch(descriptor)) ?? []
        }
    }

    static func series(
        container: ModelContainer,
        request: GenrePageRequest,
        sortBy: [SortDescriptor<Series>]
    ) -> GenrePage {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Series>(predicate: seriesPredicate(request: request), sortBy: sortBy)
        descriptor.fetchLimit = request.pageSize
        descriptor.propertiesToFetch = [\.genre, \.categoryId]
        return scan(request: request) { (offset: Int) -> [Series] in
            descriptor.fetchOffset = offset
            return (try? context.fetch(descriptor)) ?? []
        }
    }

    /// The playlist scope and the hidden-category exclusion run in SQLite, in
    /// the shape `searchMoviePredicate` established, so a page isn't spent on
    /// rows the viewer will never see — the offset used to walk every
    /// playlist's titles and then throw all but one playlist's away.
    /// `starts(with:)` compiles to a range seek on the unique `id` index, which
    /// is the only part of this predicate an index can serve: the genre match
    /// has to stay a substring test because the column holds several free-text
    /// genres per title.
    private static func moviePredicate(request: GenrePageRequest) -> Predicate<Movie> {
        let (genre, prefix) = (request.genre, request.playlistPrefix)
        let excluded = Set(request.excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        return #Predicate { movie in
            movie.id.starts(with: prefix)
                && (movie.genre?.localizedStandardContains(genre) ?? false)
                && (!filtersCategories || movie.categoryId == nil || !excluded.contains(movie.categoryId))
        }
    }

    private static func seriesPredicate(request: GenrePageRequest) -> Predicate<Series> {
        let (genre, prefix) = (request.genre, request.playlistPrefix)
        let excluded = Set(request.excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        return #Predicate { series in
            series.id.starts(with: prefix)
                && (series.genre?.localizedStandardContains(genre) ?? false)
                && (!filtersCategories || series.categoryId == nil || !excluded.contains(series.categoryId))
        }
    }

    /// Walks source pages from `request.offset` until one yields a displayable
    /// row, the source runs out, or `genreScanBudget` is spent.
    ///
    /// The loop is needed because the in-memory re-checks can empty a whole
    /// source page — `GenreParser` keeps `&` intact, so a tile for "Action"
    /// fetches every "Action & Adventure" title and then drops it again — and
    /// without new trailing items the grid never fires `onLoadMore` again,
    /// stalling pagination. The budget is what bounds it: the caller resumes
    /// from the returned cursor instead of the loop running until it finds
    /// something.
    private static func scan(
        request: GenrePageRequest,
        fetch: (Int) -> [some PersistentModel & GenreCarrying]
    ) -> GenrePage {
        let excluded = request.excludedCategoryIDs
        var page = GenrePage()
        while page.ids.isEmpty, !page.reachedEnd, page.scanned < genreScanBudget {
            let rows = fetch(request.offset + page.scanned)
            page.scanned += rows.count
            if rows.count < request.pageSize { page.reachedEnd = true }
            // The exact-token re-check keeps a substring hit out, and the
            // `excludingRestricted` filter is inlined so this stays
            // `nonisolated` — the same trade `GenreDerivation.derive` makes.
            page.ids = rows
                .filter { GenreParser.contains($0.genre, genre: request.genre) && !excluded.contains($0.categoryId ?? "") }
                .map(\.persistentModelID)
        }
        return page
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
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction

    @AppStorage(SortStorageKey.movieContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @State private var movies: [Movie] = []
    @State private var canLoadMore = true
    @State private var isLoadingPage = false
    /// SQLite cursor position, distinct from `movies.count`. The exact-token and
    /// visibility re-checks drop rows the substring fetch returned, so the
    /// displayed count and the source offset diverge — the offset must track
    /// rows pulled from SQLite, not rows shown.
    @State private var fetchedCount = 0
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
            card: { MovieCardView(movie: $0, fillsWidth: true) }
        )
        .task(id: contentSortRaw) {
            guard loadedSort != contentSortRaw else { return }
            loadedSort = contentSortRaw
            // A page fetched against the previous sort's cursor is now
            // meaningless: bump the generation so it's discarded on arrival, and
            // release the in-flight guard here, since that load no longer will.
            loadGeneration += 1
            isLoadingPage = false
            movies = []
            fetchedCount = 0
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
            playlistPrefix: playlistPrefix,
            excludedCategoryIDs: restriction.excludedCategoryIDs,
            offset: fetchedCount,
            pageSize: pageSize
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
        if page.reachedEnd { canLoadMore = false }
        movies.append(contentsOf: page.ids.compactMap { modelContext.model(for: $0) as? Movie })
        if page.ids.isEmpty, canLoadMore { loadNextPage() }
    }
}

/// The full grid of series in a genre; paged off the main actor exactly as
/// `MovieGenreView` is.
struct SeriesGenreView: View {
    let genre: String
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction

    @AppStorage(SortStorageKey.seriesContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @State private var series: [Series] = []
    @State private var canLoadMore = true
    @State private var isLoadingPage = false
    /// SQLite cursor position, distinct from `series.count` — see `MovieGenreView`.
    @State private var fetchedCount = 0
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
            card: { SeriesCardView(series: $0, fillsWidth: true) }
        )
        .task(id: contentSortRaw) {
            guard loadedSort != contentSortRaw else { return }
            loadedSort = contentSortRaw
            loadGeneration += 1
            isLoadingPage = false
            series = []
            fetchedCount = 0
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
            playlistPrefix: playlistPrefix,
            excludedCategoryIDs: restriction.excludedCategoryIDs,
            offset: fetchedCount,
            pageSize: pageSize
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
        if page.reachedEnd { canLoadMore = false }
        series.append(contentsOf: page.ids.compactMap { modelContext.model(for: $0) as? Series })
        if page.ids.isEmpty, canLoadMore { loadNextPage() }
    }
}

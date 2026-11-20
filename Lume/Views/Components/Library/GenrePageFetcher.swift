//
//  GenrePageFetcher.swift
//  Lume
//
//  The off-main page fetch behind the Movie and Series genre grids
//  (`GenreBrowse.swift`).
//

import Foundation
import SwiftData

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
    /// The playlists whose titles the grid shows, matched in SQLite on their
    /// `"<playlistUUID>-"` id prefixes rather than after materialization.
    let scope: CatalogScope
    let excludedCategoryIDs: Set<String>
    /// Where in the source rows to resume; see `GenrePage.scanned`.
    let offset: Int
    let pageSize: Int
    /// Lists each title once: only category primaries are read, and those are
    /// grouped across categories and playlists by `TitleGrouping.page`.
    var grouped = false
    /// Titles earlier grouped pages already showed; see `GenrePage.seenKeys`.
    var seenKeys: Set<String> = []
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
    /// Every title shown so far when grouped, which the next request carries
    /// so a title filed in a later category isn't shown again.
    var seenKeys: Set<String> = []
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
        guard request.grouped else {
            return scan(request: request) { (offset: Int) -> [Movie] in
                descriptor.fetchOffset = offset
                return (try? context.fetch(descriptor)) ?? []
            }
        }
        descriptor.propertiesToFetch = [\.genre, \.categoryId, \.name, \.titleGroupKey]
        let candidates = moviePredicate(request: request)
        return groupedPage(
            request: request,
            fetch: { (offset: Int, limit: Int) -> [Movie] in
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = limit
                return (try? context.fetch(descriptor)) ?? []
            },
            siblings: { keys in
                let wanted = Set(keys.map(String?.some))
                var siblings = FetchDescriptor<Movie>(predicate: #Predicate { movie in
                    wanted.contains(movie.titleGroupKey) && candidates.evaluate(movie)
                })
                siblings.propertiesToFetch = [\.genre, \.categoryId, \.name, \.titleGroupKey]
                return (try? context.fetch(siblings)) ?? []
            }
        )
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
        guard request.grouped else {
            return scan(request: request) { (offset: Int) -> [Series] in
                descriptor.fetchOffset = offset
                return (try? context.fetch(descriptor)) ?? []
            }
        }
        descriptor.propertiesToFetch = [\.genre, \.categoryId, \.name, \.titleGroupKey]
        let candidates = seriesPredicate(request: request)
        return groupedPage(
            request: request,
            fetch: { (offset: Int, limit: Int) -> [Series] in
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = limit
                return (try? context.fetch(descriptor)) ?? []
            },
            siblings: { keys in
                let wanted = Set(keys.map(String?.some))
                var siblings = FetchDescriptor<Series>(predicate: #Predicate { series in
                    wanted.contains(series.titleGroupKey) && candidates.evaluate(series)
                })
                siblings.propertiesToFetch = [\.genre, \.categoryId, \.name, \.titleGroupKey]
                return (try? context.fetch(siblings)) ?? []
            }
        )
    }

    /// The playlist scope and the hidden-category exclusion run in SQLite, in
    /// the shape `searchMoviePredicate` established, so a page isn't spent on
    /// rows the viewer will never see — the offset used to walk every
    /// playlist's titles and then throw all but one playlist's away.
    /// `starts(with:)` compiles to a range seek on the unique `id` index, which
    /// is the only part of this predicate an index can serve: the genre match
    /// has to stay a substring test because the column holds several free-text
    /// genres per title. One contributing playlist inlines that `starts(with:)`
    /// exactly as isolated mode always had it; several compose the scope's OR
    /// via `evaluate`.
    private static func moviePredicate(request: GenrePageRequest) -> Predicate<Movie> {
        let genre = request.genre
        let excluded = Set(request.excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        let grouped = request.grouped
        if let prefix = request.scope.singlePrefix(for: .movies) {
            return #Predicate { movie in
                movie.id.starts(with: prefix)
                    && (movie.genre?.localizedStandardContains(genre) ?? false)
                    && (!filtersCategories || movie.categoryId == nil || !excluded.contains(movie.categoryId))
                    && (!grouped || movie.isCategoryGroupPrimary == true)
            }
        }
        let scoped = request.scope.moviePredicate()
        return #Predicate { movie in
            scoped.evaluate(movie)
                && (movie.genre?.localizedStandardContains(genre) ?? false)
                && (!filtersCategories || movie.categoryId == nil || !excluded.contains(movie.categoryId))
                && (!grouped || movie.isCategoryGroupPrimary == true)
        }
    }

    private static func seriesPredicate(request: GenrePageRequest) -> Predicate<Series> {
        let genre = request.genre
        let excluded = Set(request.excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        let grouped = request.grouped
        if let prefix = request.scope.singlePrefix(for: .series) {
            return #Predicate { series in
                series.id.starts(with: prefix)
                    && (series.genre?.localizedStandardContains(genre) ?? false)
                    && (!filtersCategories || series.categoryId == nil || !excluded.contains(series.categoryId))
                    && (!grouped || series.isCategoryGroupPrimary == true)
            }
        }
        let scoped = request.scope.seriesPredicate()
        return #Predicate { series in
            scoped.evaluate(series)
                && (series.genre?.localizedStandardContains(genre) ?? false)
                && (!filtersCategories || series.categoryId == nil || !excluded.contains(series.categoryId))
                && (!grouped || series.isCategoryGroupPrimary == true)
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
        var page = GenrePage()
        while page.ids.isEmpty, !page.reachedEnd, page.scanned < genreScanBudget {
            let rows = fetch(request.offset + page.scanned)
            page.scanned += rows.count
            if rows.count < request.pageSize { page.reachedEnd = true }
            page.ids = rows.filter { isShown($0, for: request) }.map(\.persistentModelID)
        }
        return page
    }

    /// One full page of titles, each once across every category and playlist
    /// in scope. Unlike `scan` it reads on until the page is full or the source
    /// runs out: a page short of `pageSize` would leave the grid without
    /// enough new trailing cells to ask for the next one.
    private static func groupedPage<Row: PersistentModel & GenreCarrying & TitleGroupedRow>(
        request: GenrePageRequest,
        fetch: (_ offset: Int, _ limit: Int) -> [Row],
        siblings: ([String]) -> [Row]
    ) -> GenrePage {
        let page = TitleGrouping.page(
            after: TitleGrouping.Cursor(offset: request.offset, seenKeys: request.seenKeys),
            limit: request.pageSize,
            ranking: TitleGrouping.Ranking(scope: request.scope),
            grouped: true,
            fetch: fetch,
            includes: { isShown($0, for: request) },
            siblings: siblings
        )
        return GenrePage(
            ids: page.rows.map(\.persistentModelID),
            scanned: page.cursor.offset - request.offset,
            reachedEnd: page.cursor.isExhausted,
            seenKeys: page.cursor.seenKeys
        )
    }

    /// The exact-token re-check keeps a substring hit out, and the
    /// `excludingRestricted` filter is inlined so this stays `nonisolated` —
    /// the same trade `GenreDerivation.derive` makes.
    private static func isShown(_ row: some GenreCarrying, for request: GenrePageRequest) -> Bool {
        GenreParser.contains(row.genre, genre: request.genre) && !request.excludedCategoryIDs.contains(row.categoryId ?? "")
    }
}

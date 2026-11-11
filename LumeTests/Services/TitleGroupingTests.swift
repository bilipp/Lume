//
//  TitleGroupingTests.swift
//  LumeTests
//
//  One card per title on in-memory surfaces, the paging that keeps those
//  surfaces in full pages, and the category grid's primary-flag predicate.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct TitleGroupingTests {
    private static let first = UUID()
    private static let second = UUID()

    private static let combined = CatalogScope.combined([
        (id: first, tabs: Set(PlaylistTab.allCases)),
        (id: second, tabs: Set(PlaylistTab.allCases))
    ])

    private static let ranking = TitleGrouping.Ranking(scope: combined, preferredLanguages: [])

    private func movie(
        _ suffix: String,
        _ name: String,
        playlist: UUID = first,
        category: String = "cat",
        in context: ModelContext
    ) -> Movie {
        let movie = Movie(id: "\(playlist.uuidString)-movie-\(suffix)", streamId: 0, name: name)
        movie.categoryId = category
        movie.titleGroupKey = TitleGroupKey.movie(tmdbId: nil, name: name)
        context.insert(movie)
        return movie
    }

    // MARK: Dedupe

    @Test func `combined priority picks the representative before quality`() throws {
        try OnDiskCatalogStore.withContext { context in
            let lowerUHD = movie("1", "Inception (2010) 4K", playlist: Self.second, in: context)
            let firstSD = movie("2", "Inception (2010) SD", playlist: Self.first, in: context)
            let rows = TitleGrouping.dedupe([lowerUHD, firstSD], ranking: Self.ranking, grouped: true)
            #expect(rows.map(\.id) == [firstSD.id])
        }
    }

    @Test func `quality decides within one member`() throws {
        try OnDiskCatalogStore.withContext { context in
            let fhd = movie("1", "Inception (2010) FHD", in: context)
            let uhd = movie("2", "Inception (2010) 4K", in: context)
            let other = movie("3", "Heat (1995)", in: context)
            let rows = TitleGrouping.dedupe([fhd, other, uhd], ranking: Self.ranking, grouped: true)
            #expect(rows.map(\.id) == [uhd.id, other.id], "The title keeps its first copy's position")
        }
    }

    @Test func `preferred language breaks a quality tie`() throws {
        try OnDiskCatalogStore.withContext { context in
            let english = movie("1", "EN | Inception (2010) FHD", in: context)
            let german = movie("2", "DE | Inception (2010) FHD", in: context)
            let ranking = TitleGrouping.Ranking(scope: Self.combined, preferredLanguages: ["de"])
            #expect(TitleGrouping.dedupe([english, german], ranking: ranking, grouped: true).map(\.id) == [german.id])
        }
    }

    @Test func `rows without a key are never grouped`() throws {
        try OnDiskCatalogStore.withContext { context in
            let blankA = movie("1", " - ", in: context)
            let blankB = movie("2", " - ", in: context)
            #expect(blankA.titleGroupKey == nil)
            let rows = TitleGrouping.dedupe([blankA, blankB], ranking: Self.ranking, grouped: true)
            #expect(rows.map(\.id) == [blankA.id, blankB.id])
        }
    }

    @Test func `grouping off returns every row`() throws {
        try OnDiskCatalogStore.withContext { context in
            let fhd = movie("1", "Inception (2010) FHD", in: context)
            let uhd = movie("2", "Inception (2010) 4K", in: context)
            #expect(TitleGrouping.dedupe([fhd, uhd], ranking: Self.ranking, grouped: false).count == 2)
        }
    }

    // MARK: Detail rails

    @Test func `grouped rail shows the scope's best copy and never the shown title`() throws {
        try OnDiskCatalogStore.withContext { context in
            let shown = movie("1", "Heat (1995)", in: context)
            let shownCopy = movie("2", "Heat (1995) 4K", playlist: Self.second, in: context)
            let otherSD = movie("3", "Inception (2010) SD", in: context)
            let otherUHD = movie("4", "Inception (2010) 4K", playlist: Self.second, in: context)
            let row = TitleGrouping.railRow(
                [shownCopy, otherSD, otherUHD], excluding: shown,
                tab: .movies, ranking: Self.ranking, grouped: true
            )
            #expect(row?.id == otherSD.id, "The first scope member wins before quality")
            let onlyOwn = TitleGrouping.railRow(
                [shown, shownCopy], excluding: shown,
                tab: .movies, ranking: Self.ranking, grouped: true
            )
            #expect(onlyOwn == nil)
        }
    }

    @Test func `ungrouped rail stays on the shown row's playlist`() throws {
        try OnDiskCatalogStore.withContext { context in
            let shown = movie("1", "Heat (1995)", in: context)
            let elsewhere = movie("2", "Inception (2010) 4K", playlist: Self.second, in: context)
            let ownPlaylist = movie("3", "Inception (2010) SD", in: context)
            let row = TitleGrouping.railRow(
                [elsewhere, ownPlaylist], excluding: shown,
                tab: .movies, ranking: Self.ranking, grouped: false
            )
            #expect(row?.id == ownPlaylist.id)
        }
    }

    // MARK: Paging

    /// Raw order: A A B C C C D E (eight rows, five titles).
    private func pagedRows(in context: ModelContext) -> [Movie] {
        [
            movie("01", "Alpha (2001) HD", in: context),
            movie("02", "Alpha (2001) 4K", in: context),
            movie("03", "Bravo (2002)", in: context),
            movie("04", "Charlie (2003) SD", in: context),
            movie("05", "Charlie (2003) FHD", in: context),
            movie("06", "Charlie (2003) HD", in: context),
            movie("07", "Delta (2004)", in: context),
            movie("08", "Echo (2005)", in: context)
        ]
    }

    private func page(
        _ rows: [Movie],
        after cursor: TitleGrouping.Cursor,
        limit: Int,
        overFetch: Int = 1,
        grouped: Bool = true
    ) -> TitleGrouping.Page<Movie> {
        TitleGrouping.page(
            after: cursor, limit: limit, overFetch: overFetch, ranking: Self.ranking, grouped: grouped,
            fetch: { offset, limit in Array(rows.dropFirst(offset).prefix(limit)) }
        )
    }

    @Test func `pages are full and continue past the last row they read`() throws {
        try OnDiskCatalogStore.withContext { context in
            let rows = pagedRows(in: context)
            let one = page(rows, after: .start, limit: 2)
            #expect(one.rows.map(\.name) == ["Alpha (2001) 4K", "Bravo (2002)"])
            #expect(one.cursor.offset == 3)
            #expect(one.hasMore)

            let two = page(rows, after: one.cursor, limit: 2)
            #expect(two.rows.map(\.name) == ["Charlie (2003) FHD", "Delta (2004)"])
            #expect(two.cursor.offset == 7)
            #expect(two.hasMore)

            let three = page(rows, after: two.cursor, limit: 2)
            #expect(three.rows.map(\.name) == ["Echo (2005)"])
            #expect(!three.hasMore)
        }
    }

    @Test func `a title split across pages is shown once`() throws {
        try OnDiskCatalogStore.withContext { context in
            let rows = pagedRows(in: context)
            // Three titles per page, no over-fetch: the first page stops mid-Charlie.
            let one = page(rows, after: .start, limit: 3)
            let two = page(rows, after: one.cursor, limit: 3)
            let names = (one.rows + two.rows).map(\.name)
            #expect(names == ["Alpha (2001) 4K", "Bravo (2002)", "Charlie (2003) FHD", "Delta (2004)", "Echo (2005)"])
            #expect(!two.hasMore)
        }
    }

    @Test func `over-fetch fills a page from one read`() throws {
        try OnDiskCatalogStore.withContext { context in
            let rows = pagedRows(in: context)
            var reads = 0
            let result = TitleGrouping.page(
                after: .start, limit: 3, overFetch: 3, ranking: Self.ranking, grouped: true,
                fetch: { offset, limit in
                    reads += 1
                    return Array(rows.dropFirst(offset).prefix(limit))
                }
            )
            #expect(result.rows.count == 3)
            #expect(reads == 1)
            #expect(result.hasMore)
        }
    }

    @Test func `the last page is exhausted when only copies remain`() throws {
        try OnDiskCatalogStore.withContext { context in
            let rows = Array(pagedRows(in: context).prefix(6))
            let result = page(rows, after: .start, limit: 3, overFetch: 3)
            #expect(result.rows.count == 3)
            #expect(!result.hasMore, "Rows after the page are copies of titles already on it")
        }
    }

    @Test func `siblings beyond the window choose the representative`() throws {
        try OnDiskCatalogStore.withContext { context in
            let rows = pagedRows(in: context)
            let outside = movie("99", "Alpha (2001) 4K", playlist: Self.first, in: context)
            let hdCopy = rows[0]
            let result = TitleGrouping.page(
                after: .start, limit: 1, overFetch: 1, ranking: Self.ranking, grouped: true,
                fetch: { offset, _ in offset == 0 ? [hdCopy] : [] },
                siblings: { keys in keys.contains(hdCopy.titleGroupKey ?? "") ? [hdCopy, outside] : [] }
            )
            #expect(result.rows.map(\.id) == [outside.id])
        }
    }

    @Test func `grouping off pages the raw rows`() throws {
        try OnDiskCatalogStore.withContext { context in
            let rows = pagedRows(in: context)
            let one = page(rows, after: .start, limit: 5, grouped: false)
            #expect(one.rows.count == 5)
            #expect(one.cursor.offset == 5)
            let two = page(rows, after: one.cursor, limit: 5, grouped: false)
            #expect(two.rows.count == 3)
            #expect(!two.hasMore)
        }
    }

    // MARK: Genre grid paging

    @Test func `a grouped genre page shows a title filed in two categories once`() throws {
        try OnDiskCatalogStore.withContext { context in
            let rows = [
                movie("1", "Inception (2010) HD", category: "action", in: context),
                movie("2", "Heat (1995)", category: "action", in: context),
                movie("3", "Inception (2010) 4K", category: "thriller", in: context),
                movie("4", "Alien (1979)", category: "thriller", in: context),
                movie("5", "Heat (1995)", category: "crime", in: context),
                movie("6", "Ronin (1998)", category: "crime", in: context),
                movie("7", "Up (2009)", category: "family", in: context)
            ]
            for row in rows {
                row.genre = "Action & Adventure, Action"
            }
            rows[6].genre = "Action & Adventure"
            try context.save()

            let request = { (offset: Int, seenKeys: Set<String>, grouped: Bool) in
                GenrePageRequest(
                    genre: "Action", scope: Self.combined, excludedCategoryIDs: [], offset: offset, pageSize: 2,
                    grouped: grouped, seenKeys: seenKeys
                )
            }
            let sortBy = [SortDescriptor(\Movie.id)]
            let one = GenrePageFetcher.movies(container: context.container, request: request(0, [], true), sortBy: sortBy)
            #expect(one.ids == [rows[2].persistentModelID, rows[1].persistentModelID], "The 4K copy stands for Inception")
            #expect(one.scanned == 2)
            #expect(!one.reachedEnd)

            let two = GenrePageFetcher.movies(
                container: context.container, request: request(one.scanned, one.seenKeys, true), sortBy: sortBy
            )
            #expect(two.ids == [rows[3].persistentModelID, rows[5].persistentModelID], "Heat is not shown again")
            #expect(two.reachedEnd)

            let raw = GenrePageFetcher.movies(container: context.container, request: request(0, [], false), sortBy: sortBy)
            #expect(raw.ids == [rows[0].persistentModelID, rows[1].persistentModelID])
        }
    }

    // MARK: Category grid predicate

    @Test func `grouped category grids list only primaries`() throws {
        try OnDiskCatalogStore.withContext { context in
            let primary = movie("1", "Inception (2010) 4K", in: context)
            let copy = movie("2", "Inception (2010) HD", in: context)
            copy.isCategoryGroupPrimary = false
            _ = movie("3", "Heat (1995)", category: "other", in: context)
            try context.save()

            let grouped = try context.fetch(CategoryGridQuery.movies(categoryId: "cat", grouped: true))
            #expect(grouped.map(\.id) == [primary.id])
            let raw = try context.fetch(CategoryGridQuery.movies(categoryId: "cat", grouped: false))
            #expect(Set(raw.map(\.id)) == [primary.id, copy.id])
        }
    }
}

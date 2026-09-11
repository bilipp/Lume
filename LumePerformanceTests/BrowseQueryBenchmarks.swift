//
//  BrowseQueryBenchmarks.swift
//  LumePerformanceTests
//
//  The fetches behind browsing: the Movies/Series collection rails, the Live TV
//  section gates, a category preview row, and search.
//
//  Every one of these was measured on a real 284k-row Xtream catalog and found
//  to be scanning where it should have been seeking. On that store, per
//  interaction, before the browse-latency work:
//
//      cold launch -> Home      1,904 ms of SQL   (10,412 fetches)
//      Movies tab switch          739 ms          ( 7,883 fetches)
//      one "Add to Favorites"   1,158 ms          (23,991 fetches)
//
//  and after it, 774 / 91 / 145 ms. The rest of this target measures the sync
//  and import path; `EPGQueryBenchmarks` measures the two guide loaders. This
//  file is the browse read path, which nothing covered.
//
//  What each benchmark is actually guarding is written on the test. They are
//  mostly one-token regressions — a `sortBy:` added back to a bounded fetch, a
//  `fetchLimit` dropped, `comparator: .lexical` lost to the default — that
//  change no visible row and so survive review and the unit suite. The cheap
//  deterministic half of that guard lives in
//  `LumeTests/Services/BrowseQueryShapeTests.swift`; this half is the cost.
//
//  Scale note: 20k movies / 6k series / 8k channels, the same order as
//  `PersistenceBenchmarks` uses, not the 284k of the measured provider. Big
//  enough that an unindexed scan separates from an index seek by more than the
//  noise floor, small enough to seed in seconds. When chasing a specific
//  regression, raise the counts locally.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

final class BrowseQueryBenchmarks: XCTestCase {
    private var store: (container: ModelContainer, directory: URL)!

    private let movieCount = 20000
    private let seriesCount = 6000
    private let channelCount = 8000
    private let categoryCount = 200

    /// Proportions taken from the heavy-user state the audit measured (1,506
    /// favorites and 5,069 watch-history rows against 284k titles), scaled down
    /// with the catalog. A fresh install exercises none of these paths, which is
    /// exactly why the regressions went unnoticed for so long.
    private var favoriteEvery: Int {
        40
    }

    private var watchedEvery: Int {
        12
    }

    private var hiddenEvery: Int {
        19
    }

    /// The section gates are sub-millisecond when they are working, which is
    /// below what `XCTClockMetric` can resolve on a single call — a regression
    /// from 0.02 ms to 8 ms would still read as "0.000 s". Each probe benchmark
    /// therefore runs the fetch as many times as one measured cold launch did
    /// (18-25), which puts the fast case just above the timer floor and the
    /// unbounded case far above it.
    private let probeRepeats = 25

    /// The active playlist. Row ids are `"<uuid>-<kind>-<n>"`, the shape
    /// `ContentSyncManager` writes and every browse predicate scopes on;
    /// `Category` derives the same shape from its `playlist` in `init`.
    /// `Playlist` mints its own id, so both are read back after seeding.
    private var playlistID: UUID!
    /// A second installed playlist. It exists so the scoping predicates have
    /// something to exclude: the bug this guards against is a fetch that reads
    /// every playlist's rows and filters in Swift afterwards, which is invisible
    /// until a second playlist is installed.
    private var otherPlaylistID: UUID!

    private var prefix: String {
        "\(playlistID.uuidString)-"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try PerfStore.makeOnDiskContainer()
        seedCatalog()
    }

    override func tearDownWithError() throws {
        if let store {
            PerfStore.destroy(directory: store.directory)
        }
        store = nil
        try super.tearDownWithError()
    }

    // MARK: - Collection rails

    /// "Recently Added" on the Movies tab. The most expensive single query in
    /// the app before the fix: `Movie.added` carried no index *and* the default
    /// `SortDescriptor` comparator emitted `COLLATE NSCollateFinderlike`, so the
    /// plan was `SCAN ZMOVIE` plus a temp B-tree sort of every row — 222 ms per
    /// run on 179k titles, re-run on every catalog write.
    ///
    /// Two independent things keep it fast, and losing either brings the scan
    /// back: the `#Index<Movie>([\.added])` entry, and `comparator: .lexical` on
    /// the sort. A binary index cannot serve a localized collation.
    func testRecentlyAddedMovieRail() {
        let descriptor = MovieCollectionQuery.rowDescriptor(for: .recentlyAdded, playlistPrefix: prefix)
        let context = ModelContext(store.container)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let rows = (try? context.fetch(descriptor)) ?? []
            XCTAssertEqual(rows.count, collectionRowFetchLimit)
        }
    }

    /// The Series equivalent, sorting on `lastModified` — same index and same
    /// comparator dependency.
    func testRecentlyAddedSeriesRail() {
        let descriptor = SeriesCollectionQuery.rowDescriptor(for: .recentlyAdded, playlistPrefix: prefix)
        let context = ModelContext(store.container)

        measure(metrics: [XCTClockMetric()]) {
            let rows = (try? context.fetch(descriptor)) ?? []
            XCTAssertEqual(rows.count, collectionRowFetchLimit)
        }
    }

    /// The Favorites rail. This one fetched *every* favorite across *every*
    /// playlist and then took `prefix(20)` in Swift: 0.85 ms with no favorites,
    /// 59 ms with a few thousand, re-run on every write anywhere in the app.
    /// Guards the `fetchLimit` and the in-SQL playlist scope together.
    func testFavoritesMovieRail() {
        let descriptor = MovieCollectionQuery.rowDescriptor(for: .favorites, playlistPrefix: prefix)
        let context = ModelContext(store.container)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let rows = (try? context.fetch(descriptor)) ?? []
            XCTAssertFalse(rows.isEmpty)
            XCTAssertLessThanOrEqual(rows.count, collectionRowFetchLimit)
        }
    }

    /// Recently Watched, same shape as Favorites but ordered by a date index.
    func testRecentlyWatchedMovieRail() {
        let descriptor = MovieCollectionQuery.rowDescriptor(for: .recentlyWatched, playlistPrefix: prefix)
        let context = ModelContext(store.container)

        measure(metrics: [XCTClockMetric()]) {
            let rows = (try? context.fetch(descriptor)) ?? []
            XCTAssertFalse(rows.isEmpty)
            XCTAssertLessThanOrEqual(rows.count, collectionRowFetchLimit)
        }
    }

    /// The "Show All" grid behind Favorites, which is unbounded on purpose — the
    /// surface that legitimately shows everything. Measured so that "unbounded"
    /// stays a deliberate cost on one screen rather than something that creeps
    /// back into the rails.
    func testFavoritesMovieGrid() {
        let descriptor = MovieCollectionQuery.gridDescriptor(for: .favorites, playlistPrefix: prefix)
        let context = ModelContext(store.container)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let rows = (try? context.fetch(descriptor)) ?? []
            XCTAssertFalse(rows.isEmpty)
        }
    }

    // MARK: - Live TV section gates

    /// Whether the Favorites rail row should exist at all. The rail used to
    /// answer this by materializing every favorited channel and filtering in
    /// Swift — 7.6 ms a call, and the call happened 18-25 times on a cold launch
    /// of a tab the viewer may never open. It is a `LIMIT 1` probe now.
    ///
    /// Also guards the composite `#Index<LiveStream>([\.isFavorite, \.isHidden])`:
    /// with only the single-column indexes, SQLite picked the `isHidden` one,
    /// which matches almost every channel in the table.
    func testLiveFavoritesProbe() {
        let descriptor = LiveChannelQuery.favoritesProbe(playlistPrefix: prefix, restriction: ContentRestriction())
        let context = ModelContext(store.container)

        measure(metrics: [XCTClockMetric()]) {
            for _ in 0 ..< probeRepeats {
                let rows = (try? context.fetch(descriptor)) ?? []
                XCTAssertEqual(rows.count, 1)
            }
        }
    }

    /// The Recently Watched gate. Guards
    /// `#Index<LiveStream>([\.isHidden, \.lastWatchedDate])` — and its column
    /// order specifically: the intuitive `[lastWatchedDate, isHidden]` is *not*
    /// chosen without table statistics, which Core Data never generates, so the
    /// plan silently falls back to the whole-table `isHidden` index.
    func testLiveRecentlyWatchedProbe() {
        let descriptor = LiveChannelQuery.recentlyWatchedProbe(playlistPrefix: prefix, restriction: ContentRestriction())
        let context = ModelContext(store.container)

        measure(metrics: [XCTClockMetric()]) {
            for _ in 0 ..< probeRepeats {
                let rows = (try? context.fetch(descriptor)) ?? []
                XCTAssertEqual(rows.count, 1)
            }
        }
    }

    /// The same gate for a viewer with categories locked away, where the
    /// exclusion set becomes an `IN (…)` clause alongside the index seek. A
    /// child profile on a large playlist is the worst shape this predicate takes.
    func testLiveFavoritesProbeWithRestrictions() {
        let restriction = ContentRestriction(
            isActive: true,
            restrictedCategoryIDs: Set((0 ..< 40).map { "\(prefix)live-cat\($0)" }),
            hiddenCategoryIDs: Set((40 ..< 80).map { "\(prefix)live-cat\($0)" })
        )
        let descriptor = LiveChannelQuery.favoritesProbe(playlistPrefix: prefix, restriction: restriction)
        let context = ModelContext(store.container)

        measure(metrics: [XCTClockMetric()]) {
            for _ in 0 ..< probeRepeats {
                _ = (try? context.fetch(descriptor)) ?? []
            }
        }
    }

    /// A whole live category's channel list — the fetch behind opening a
    /// category in Live TV, served by `[\.categoryId, \.isHidden]`.
    func testLiveCategoryChannelList() {
        let scope = LiveChannelScope.category("\(prefix)live-cat0")
        let descriptor = LiveChannelQuery.descriptor(for: scope, sort: .playlist)
        let context = ModelContext(store.container)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let rows = (try? context.fetch(descriptor)) ?? []
            XCTAssertFalse(rows.isEmpty)
        }
    }

    // MARK: - Category preview

    /// One category preview row on the Movies tab. Four of these mount at once,
    /// and they re-fetch on every catalog write, so the per-row cost is
    /// multiplied by four and then by however often something saves.
    func testMovieCategoryPreviewRow() {
        let categoryId = "\(prefix)vod-cat0"
        var descriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.categoryId == categoryId },
            sortBy: ContentSortOption.playlist.movieDescriptors
        )
        descriptor.fetchLimit = 21
        let context = ModelContext(store.container)

        measure(metrics: [XCTClockMetric()]) {
            let rows = (try? context.fetch(descriptor)) ?? []
            XCTAssertEqual(rows.count, 21)
        }
    }

    // MARK: - Search

    /// A common term, which is what every intermediate keystroke of a real query
    /// looks like. This is the one `sortBy:` guards: with an ORDER BY, SQLite
    /// must find *and sort* every match before it can apply `LIMIT 50`, so a
    /// bounded fetch still scanned the whole table. Measured on the real store,
    /// 66 ms -> 0.4 ms once the sort moved to the 50 hydrated rows.
    ///
    /// If this benchmark ever approaches `testSearchRareTerm`, a `sortBy:` has
    /// come back.
    func testSearchCommonTerm() {
        let request = searchRequest(query: "the")

        measure(metrics: [XCTClockMetric()]) {
            let hits = SearchFetcher.fetch(container: store.container, request: request)
            XCTAssertEqual(hits.movies.count, request.limit)
        }
    }

    /// A term that matches almost nothing. The scan runs to the end whatever the
    /// sort does, so this is the floor set by `localizedStandardContains` being
    /// unindexable — the number to beat if a normalized search column ever lands.
    func testSearchRareTerm() {
        let request = searchRequest(query: "zzqxv")

        measure(metrics: [XCTClockMetric()]) {
            let hits = SearchFetcher.fetch(container: store.container, request: request)
            XCTAssertTrue(hits.movies.isEmpty)
        }
    }

    /// Search restricted to the active playlist. The scope used to be a second
    /// `localizedStandardContains`, on `categoryId` — a full substring search
    /// used as a prefix test, as expensive again as the name match it was paired
    /// with. It is a `starts(with:)` on the indexed id now.
    func testSearchScopedToPlaylist() {
        let request = searchRequest(query: "the", restrictToPlaylist: true)

        measure(metrics: [XCTClockMetric()]) {
            let hits = SearchFetcher.fetch(container: store.container, request: request)
            XCTAssertFalse(hits.movies.isEmpty)
        }
    }

    private func searchRequest(query: String, restrictToPlaylist: Bool = false) -> SearchRequest {
        SearchRequest(
            query: query,
            playlistID: playlistID.uuidString,
            restrictToPlaylist: restrictToPlaylist,
            wantMovies: true,
            wantSeries: false,
            wantLive: false,
            excludedCategoryIDs: [],
            limit: 50
        )
    }

    // MARK: - Seeding

    /// Builds a catalog shaped like a provider's, across two playlists, with the
    /// user state the browse predicates actually filter on.
    ///
    /// Seeded once per test in `setUp` and never inside a measured block —
    /// writing these rows costs far more than any query being measured.
    private func seedCatalog() {
        let context = ModelContext(store.container)
        context.autosaveEnabled = false

        let active = Playlist(name: "Active", serverURL: "http://perf.test", username: "u", password: "p")
        let other = Playlist(name: "Other", serverURL: "http://perf.test", username: "u", password: "p")
        context.insert(active)
        context.insert(other)
        playlistID = active.id
        otherPlaylistID = other.id

        seedCategories(for: [active, other], in: context)
        seedMovies(in: context)
        seedSeries(in: context)
        seedChannels(in: context)

        try? context.save()
    }

    private func seedCategories(for playlists: [Playlist], in context: ModelContext) {
        for playlist in playlists {
            for index in 0 ..< categoryCount {
                for kind in [CategoryType.vod, .series, .live] {
                    context.insert(Lume.Category(
                        apiId: "cat\(index)",
                        name: "\(kind.rawValue.uppercased()) Category \(index)",
                        parentId: 0,
                        type: kind,
                        playlist: playlist
                    ))
                }
            }
        }
    }

    private func seedMovies(in context: ModelContext) {
        // Titles carry a common token ("the") and a rare one so search has both
        // a dense and a sparse case to measure; `added` is a ten-digit Unix
        // second string, the width Xtream ships and the width that makes a
        // lexical sort agree with a numeric one.
        for playlist in [playlistID!, otherPlaylistID!] {
            let scope = "\(playlist.uuidString)-"
            let isActive = playlist == playlistID
            autoreleasepool {
                for index in 0 ..< movieCount {
                    let movie = Movie(
                        id: "\(scope)vod-\(index)",
                        streamId: index,
                        name: index.isMultiple(of: 3) ? "The Feature \(index)" : "Feature \(index)",
                        added: String(1_700_000_000 + index),
                        num: index,
                        categoryId: "\(scope)vod-cat\(index % categoryCount)"
                    )
                    if isActive, index.isMultiple(of: favoriteEvery) {
                        movie.isFavorite = true
                        movie.favoriteOrder = index / favoriteEvery
                    }
                    if isActive, index.isMultiple(of: watchedEvery) {
                        movie.lastWatchedDate = Date(timeIntervalSince1970: 1_800_000_000 - Double(index))
                        movie.watchProgress = 300
                    }
                    context.insert(movie)
                }
            }
        }
    }

    private func seedSeries(in context: ModelContext) {
        for playlist in [playlistID!, otherPlaylistID!] {
            let scope = "\(playlist.uuidString)-"
            let isActive = playlist == playlistID
            autoreleasepool {
                for index in 0 ..< seriesCount {
                    let show = Series(
                        id: "\(scope)series-\(index)",
                        seriesId: index,
                        name: index.isMultiple(of: 3) ? "The Show \(index)" : "Show \(index)",
                        lastModified: String(1_700_000_000 + index),
                        num: index,
                        categoryId: "\(scope)series-cat\(index % categoryCount)"
                    )
                    if isActive, index.isMultiple(of: favoriteEvery) { show.isFavorite = true }
                    if isActive, index.isMultiple(of: watchedEvery) {
                        show.lastWatchedDate = Date(timeIntervalSince1970: 1_800_000_000 - Double(index))
                    }
                    context.insert(show)
                }
            }
        }
    }

    private func seedChannels(in context: ModelContext) {
        for playlist in [playlistID!, otherPlaylistID!] {
            let scope = "\(playlist.uuidString)-"
            let isActive = playlist == playlistID
            autoreleasepool {
                for index in 0 ..< channelCount {
                    let stream = LiveStream(
                        id: "\(scope)live-\(index)",
                        streamId: index,
                        name: "Channel \(index)",
                        num: index,
                        categoryId: "\(scope)live-cat\(index % categoryCount)"
                    )
                    // Hidden channels are the reason the composite indexes exist:
                    // almost every row is visible, so `isHidden` alone is a
                    // useless index to seek on.
                    stream.isHidden = index.isMultiple(of: hiddenEvery)
                    if isActive, index.isMultiple(of: favoriteEvery), !stream.isHidden {
                        stream.isFavorite = true
                        stream.favoriteOrder = index / favoriteEvery
                    }
                    if isActive, index.isMultiple(of: watchedEvery), !stream.isHidden {
                        stream.lastWatchedDate = Date(timeIntervalSince1970: 1_800_000_000 - Double(index))
                    }
                    context.insert(stream)
                }
            }
        }
    }
}

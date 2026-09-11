//
//  BrowseQueryShapeTests.swift
//  LumeTests
//
//  The browse fetches have performance contracts that no visible row depends on:
//  a `fetchLimit` that bounds a rail, a probe with no `sortBy`, a playlist scope
//  that runs in SQLite instead of in Swift, and a lexical comparator that is the
//  only reason an index can serve the "Recently Added" sort.
//
//  Each of those is one token. Remove it and the app still shows exactly the
//  right rows — just after scanning the whole table — so the change survives
//  review, the rest of this suite, and every screenshot. On the measured 284k-row
//  catalog those same tokens were worth 1,904 -> 774 ms on launch and
//  1,158 -> 145 ms on a single favorite tap.
//
//  `LumePerformanceTests/BrowseQueryBenchmarks.swift` measures what they cost.
//  These tests just assert they are still there, in the normal suite, on every
//  commit — which is the half that runs in CI.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct BrowseQueryShapeTests {
    private let prefix = "\(UUID().uuidString)-"

    // MARK: - Collection rails are bounded

    /// A preview row renders 20 items. It must never fetch the whole table to
    /// find them: this was the rail that went from 0.85 ms to 59 ms once a user
    /// had a few thousand watched titles, re-running on every catalog write.
    @Test func `every preview row is bounded`() {
        for kind in [LibraryCollection.Kind.recentlyWatched, .favorites, .recentlyAdded] {
            #expect(MovieCollectionQuery.rowDescriptor(for: kind, playlistPrefix: prefix).fetchLimit == collectionRowFetchLimit)
            #expect(SeriesCollectionQuery.rowDescriptor(for: kind, playlistPrefix: prefix).fetchLimit == collectionRowFetchLimit)
        }
        #expect(collectionRowFetchLimit > collectionPreviewLimit, "the cap has to leave room for `hasMore`")
    }

    /// "Show All" is the one surface that legitimately shows everything, so
    /// Recently Watched and Favorites are unbounded there on purpose. Recently
    /// Added keeps its cap because its predicate matches the whole catalog —
    /// every title has an `added` stamp.
    @Test func `show-all grids are unbounded except recently added`() {
        #expect(MovieCollectionQuery.gridDescriptor(for: .favorites, playlistPrefix: prefix).fetchLimit == nil)
        #expect(MovieCollectionQuery.gridDescriptor(for: .recentlyWatched, playlistPrefix: prefix).fetchLimit == nil)
        #expect(MovieCollectionQuery.gridDescriptor(for: .recentlyAdded, playlistPrefix: prefix).fetchLimit == recentlyAddedFetchLimit)
    }

    // MARK: - Live TV gates stay probes

    /// Both rail gates answer "is there at least one". They must stay `LIMIT 1`
    /// with no sort: a `sortBy` makes SQLite find and order every match before
    /// the limit can apply, which is exactly the work the probe exists to avoid.
    /// The unbounded version cost 7.6 ms a call, 18-25 times per cold launch, on
    /// a tab the viewer may never open.
    @Test func `live tv section gates are limit-one probes with no sort`() {
        for descriptor in [
            LiveChannelQuery.favoritesProbe(playlistPrefix: prefix, restriction: ContentRestriction()),
            LiveChannelQuery.recentlyWatchedProbe(playlistPrefix: prefix, restriction: ContentRestriction())
        ] {
            #expect(descriptor.fetchLimit == 1)
            #expect(descriptor.sortBy.isEmpty)
        }
    }

    // MARK: - The lexical comparator

    /// `added` and `lastModified` hold Unix seconds as strings. `SortDescriptor`
    /// defaults to `.localizedStandard` for String key paths, which compares
    /// them *numerically* — so this test passes either way on equal-width
    /// values, and the fixtures below are deliberately unequal in width to tell
    /// the two comparators apart.
    ///
    /// `.lexical` is what matters: it is the only comparator a binary `#Index`
    /// can serve, and the localized one emits `COLLATE NSCollateFinderlike`,
    /// which turns the "Recently Added" rail back into `SCAN ZMOVIE` plus a full
    /// temp B-tree sort — 222 ms per run on a 179k-title catalog.
    ///
    /// Real provider data is always ten digits wide, so lexical and numeric
    /// order agree in production; this asserts which one is configured.
    @Test func `newest-first sorts movies lexically, not numerically`() {
        let movies = [
            Movie(id: "a", streamId: 1, name: "A", added: "100"),
            Movie(id: "b", streamId: 2, name: "B", added: "50")
        ]
        let sorted = movies.sorted(using: ContentSortOption.newest.movieDescriptors)
        // Lexically "50" > "100"; numerically it is the other way round.
        #expect(sorted.map(\.id) == ["b", "a"])
    }

    @Test func `newest-first sorts series lexically, not numerically`() {
        let shows = [
            Series(id: "a", seriesId: 1, name: "A", lastModified: "100"),
            Series(id: "b", seriesId: 2, name: "B", lastModified: "50")
        ]
        let sorted = shows.sorted(using: ContentSortOption.newest.seriesDescriptors)
        #expect(sorted.map(\.id) == ["b", "a"])
    }

    @Test func `newest-first sorts channels lexically, not numerically`() {
        let channels = [
            LiveStream(id: "a", streamId: 1, name: "A", added: "100"),
            LiveStream(id: "b", streamId: 2, name: "B", added: "50")
        ]
        let sorted = channels.sorted(using: ContentSortOption.newest.liveStreamDescriptors)
        #expect(sorted.map(\.id) == ["b", "a"])
    }

    // MARK: - The playlist scope runs in SQLite

    /// The rails used to fetch every installed playlist's rows and filter with
    /// `id.hasPrefix` in Swift afterwards, so a user who added a big playlist
    /// permanently slowed down their small one. The scope is a predicate now.
    ///
    /// Needs an on-disk store: an in-memory one evaluates predicates without
    /// generating SQL, so a `starts(with:)` that CoreData cannot render would
    /// pass here and trap on device (see `SearchPredicateTests`).
    @Test func `collection rails only fetch the active playlist`() throws {
        let container = try makeSQLiteContainer()
        let context = ModelContext(container)
        let mine = "\(UUID().uuidString)-"
        let theirs = "\(UUID().uuidString)-"

        for (scope, count) in [(mine, 3), (theirs, 5)] {
            for index in 0 ..< count {
                let movie = Movie(
                    id: "\(scope)vod-\(index)",
                    streamId: index,
                    name: "Feature \(index)",
                    added: String(1_700_000_000 + index)
                )
                movie.isFavorite = true
                movie.lastWatchedDate = Date()
                context.insert(movie)
            }
        }
        try context.save()

        for kind in [LibraryCollection.Kind.favorites, .recentlyWatched, .recentlyAdded] {
            let rows = try context.fetch(MovieCollectionQuery.rowDescriptor(for: kind, playlistPrefix: mine))
            #expect(rows.count == 3, "\(kind) leaked rows from another playlist")
            #expect(rows.allSatisfy { $0.id.hasPrefix(mine) })
        }
    }

    /// The same property for the Live TV gates: a favorite in *another* playlist
    /// must not light up this playlist's Favorites row.
    @Test func `live tv gates only see the active playlist`() throws {
        let container = try makeSQLiteContainer()
        let context = ModelContext(container)
        let mine = "\(UUID().uuidString)-"
        let theirs = "\(UUID().uuidString)-"

        let other = LiveStream(id: "\(theirs)live-1", streamId: 1, name: "Theirs")
        other.isFavorite = true
        other.lastWatchedDate = Date()
        context.insert(other)
        try context.save()

        let restriction = ContentRestriction()
        #expect(try context.fetch(LiveChannelQuery.favoritesProbe(playlistPrefix: mine, restriction: restriction)).isEmpty)
        #expect(try context.fetch(LiveChannelQuery.recentlyWatchedProbe(playlistPrefix: mine, restriction: restriction)).isEmpty)

        let ours = LiveStream(id: "\(mine)live-1", streamId: 2, name: "Ours")
        ours.isFavorite = true
        ours.lastWatchedDate = Date()
        context.insert(ours)
        try context.save()

        #expect(try context.fetch(LiveChannelQuery.favoritesProbe(playlistPrefix: mine, restriction: restriction)).count == 1)
        #expect(try context.fetch(LiveChannelQuery.recentlyWatchedProbe(playlistPrefix: mine, restriction: restriction)).count == 1)
    }

    /// A hidden channel is the only favorite: the gate must report empty, or the
    /// rail offers a section whose list then renders nothing.
    @Test func `live tv gates respect channel visibility`() throws {
        let container = try makeSQLiteContainer()
        let context = ModelContext(container)
        let mine = "\(UUID().uuidString)-"

        let hidden = LiveStream(id: "\(mine)live-1", streamId: 1, name: "Hidden")
        hidden.isFavorite = true
        hidden.isHidden = true
        context.insert(hidden)
        try context.save()

        let probe = LiveChannelQuery.favoritesProbe(playlistPrefix: mine, restriction: ContentRestriction())
        #expect(try context.fetch(probe).isEmpty)
    }

    /// The restriction has to be *in* the predicate. With `fetchLimit = 1` and a
    /// Swift-side check, a single restricted row coming back would call the
    /// whole collection empty and drop a section full of visible channels.
    @Test func `a restricted-only favorite does not light up the rail`() throws {
        let container = try makeSQLiteContainer()
        let context = ModelContext(container)
        let mine = "\(UUID().uuidString)-"
        let locked = "\(mine)live-locked"

        let stream = LiveStream(id: "\(mine)live-1", streamId: 1, name: "Locked", categoryId: locked)
        stream.isFavorite = true
        context.insert(stream)
        try context.save()

        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: [locked])
        let probe = LiveChannelQuery.favoritesProbe(playlistPrefix: mine, restriction: restriction)
        #expect(try context.fetch(probe).isEmpty)

        // …and is offered again to a viewer the lock does not apply to.
        let parent = LiveChannelQuery.favoritesProbe(playlistPrefix: mine, restriction: ContentRestriction())
        #expect(try context.fetch(parent).count == 1)
    }

    // MARK: - Helpers

    /// The container must be held for the test's duration — see
    /// `SearchPredicateTests` for what happens when it is not.
    private func makeSQLiteContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }
}

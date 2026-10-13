//
//  CatalogScopeShapeTests.swift
//  LumeTests
//
//  `CatalogScope`'s predicates on a real store file. An in-memory store
//  evaluates predicates in Swift, so a composed `evaluate()` CoreData cannot
//  render as SQL would pass there and trap on device.
//
//  The isolated scope is the default mode, so its predicate must stay the exact
//  `id.starts(with:)` the browse queries used before scopes existed.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CatalogScopeShapeTests {
    private let first = UUID()
    private let second = UUID()
    private let outsider = UUID()

    private var combined: CatalogScope {
        .combined([(id: first, tabs: [.movies, .liveTV]), (id: second, tabs: [.movies, .series])])
    }

    private func insertCatalog(in context: ModelContext) throws {
        // The outsider's stamps are the newest, so a scope that leaks tops every rail.
        for (playlist, count, stamp) in [(first, 3, 0), (second, 4, 10), (outsider, 5, 20)] {
            let prefix = playlist.uuidString
            for index in 0 ..< count {
                context.insert(Movie(id: "\(prefix)-vod-\(index)", streamId: index, name: "Movie \(index)",
                                     added: String(1_700_000_000 + stamp + index)))
                context.insert(Series(id: "\(prefix)-series-\(index)", seriesId: index, name: "Show \(index)"))
                context.insert(LiveStream(id: "\(prefix)-live-\(index)", streamId: index, name: "Channel \(index)"))
            }
        }
        try context.save()
    }

    // MARK: - Isolated mode is unchanged

    @Test func `an isolated predicate has no evaluate node`() {
        let scope = CatalogScope.isolated(first)
        let prefix = "\(first.uuidString)-"
        let today = #Predicate<Movie> { $0.id.starts(with: prefix) }

        let built = scope.moviePredicate()
        #expect(String(describing: type(of: built.expression)) == String(describing: type(of: today.expression)))
        #expect(!String(describing: type(of: built.expression)).contains("Evaluate"))
        #expect(!String(describing: type(of: scope.liveStreamPredicate().expression)).contains("Evaluate"))
        #expect(!String(describing: type(of: scope.seriesPredicate().expression)).contains("Evaluate"))
    }

    @Test func `an isolated predicate fetches what the plain prefix fetched`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertCatalog(in: context)
            let prefix = "\(first.uuidString)-"
            let today = try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) }))
            let scoped = try context.fetch(FetchDescriptor<Movie>(predicate: CatalogScope.isolated(first).moviePredicate()))

            #expect(Set(scoped.map(\.id)) == Set(today.map(\.id)))
            #expect(scoped.count == 3)
        }
    }

    // MARK: - Combined stays in SQL

    @Test func `a combined predicate composes with evaluate`() {
        #expect(String(describing: type(of: combined.moviePredicate().expression)).contains("Evaluate"))
    }

    @Test func `a combined scope fetches only member rows`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertCatalog(in: context)
            let firstPrefix = "\(first.uuidString)-"
            let secondPrefix = "\(second.uuidString)-"

            let movies = try context.fetch(FetchDescriptor<Movie>(predicate: combined.moviePredicate()))
            #expect(movies.count == 7)
            #expect(movies.allSatisfy { $0.id.hasPrefix(firstPrefix) || $0.id.hasPrefix(secondPrefix) })

            let series = try context.fetch(FetchDescriptor<Series>(predicate: combined.seriesPredicate()))
            #expect(series.count == 4, "only the member contributing series")
            #expect(series.allSatisfy { $0.id.hasPrefix(secondPrefix) })

            let live = try context.fetch(FetchDescriptor<LiveStream>(predicate: combined.liveStreamPredicate()))
            #expect(live.count == 3)
            #expect(live.allSatisfy { $0.id.hasPrefix(firstPrefix) })
        }
    }

    /// The scope composed into a larger predicate, bounded and sorted: the
    /// shape every Recently Added rail takes.
    @Test func `a combined scope composes into a bounded sorted fetch`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertCatalog(in: context)
            let scope = combined.moviePredicate()
            var descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate { $0.added != nil && scope.evaluate($0) },
                sortBy: [SortDescriptor(\.added, comparator: .lexical, order: .reverse)]
            )
            descriptor.fetchLimit = 2

            let rows = try context.fetch(descriptor)
            #expect(rows.map(\.id) == ["\(second.uuidString)-vod-3", "\(second.uuidString)-vod-2"])
            #expect(try context.fetchCount(FetchDescriptor<Movie>(predicate: scope)) == 7)
        }
    }

    // MARK: - Empty

    @Test func `the empty scope fetches nothing`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertCatalog(in: context)
            let empty = CatalogScope.empty

            #expect(try context.fetchCount(FetchDescriptor<Movie>(predicate: empty.moviePredicate())) == 0)
            #expect(try context.fetchCount(FetchDescriptor<Series>(predicate: empty.seriesPredicate())) == 0)
            #expect(try context.fetchCount(FetchDescriptor<LiveStream>(predicate: empty.liveStreamPredicate())) == 0)
        }
    }

    @Test func `a type no member contributes fetches nothing`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertCatalog(in: context)
            let scope = CatalogScope.combined([(id: first, tabs: [.movies]), (id: second, tabs: [.movies])])

            #expect(try context.fetchCount(FetchDescriptor<LiveStream>(predicate: scope.liveStreamPredicate())) == 0)
            #expect(try context.fetchCount(FetchDescriptor<Movie>(predicate: scope.moviePredicate())) == 7)
        }
    }
}

// MARK: - Library rails

/// The Movies and Series rails (Recently Added, Favorites, Recently Watched):
/// the scope composed with each rail's own condition, bounded and sorted.
extension CatalogScopeShapeTests {
    /// `second` is priority 1 so member order can't pass by matching UUID or
    /// insertion order.
    private var rails: CatalogScope {
        .combined([(id: second, tabs: [.movies, .series]), (id: first, tabs: [.movies, .series])])
    }

    /// Three titles per playlist with interleaved `added` stamps, the outsider's
    /// the newest. Index 0 is a favorite, index 1 was watched.
    private func insertRailCatalog(in context: ModelContext) throws {
        for (playlist, offset) in [(first, 100), (second, 105), (outsider, 200)] {
            let prefix = playlist.uuidString
            for index in 0 ..< 3 {
                let stamp = String(1_700_000_000 + offset + index * 10)
                let movie = Movie(id: "\(prefix)-vod-\(index)", streamId: index, name: "Movie \(index)",
                                  added: stamp, num: index, categoryId: "\(prefix)-vod-cat-\(index % 2)")
                let series = Series(id: "\(prefix)-series-\(index)", seriesId: index, name: "Show \(index)",
                                    lastModified: stamp, num: index)
                movie.isFavorite = index == 0
                series.isFavorite = index == 0
                if index == 1 {
                    movie.lastWatchedDate = Date(timeIntervalSince1970: 1_700_000_000)
                    series.lastWatchedDate = Date(timeIntervalSince1970: 1_700_000_000)
                }
                context.insert(movie)
                context.insert(series)
            }
        }
        try context.save()
    }

    private func isMember(_ id: String) -> Bool {
        id.hasPrefix("\(first.uuidString)-") || id.hasPrefix("\(second.uuidString)-")
    }

    @Test func `combined recently added rails sort every member by date in SQL`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertRailCatalog(in: context)
            let movieRow = MovieCollectionQuery.rowDescriptor(for: .recentlyAdded, scope: rails)
            let seriesRow = SeriesCollectionQuery.rowDescriptor(for: .recentlyAdded, scope: rails)
            let expected = [(second, 2), (first, 2), (second, 1), (first, 1), (second, 0), (first, 0)]

            #expect(movieRow.fetchLimit == collectionRowFetchLimit)
            #expect(try context.fetch(movieRow).map(\.id) == expected.map { "\($0.0.uuidString)-vod-\($0.1)" })
            #expect(try context.fetch(seriesRow).map(\.id) == expected.map { "\($0.0.uuidString)-series-\($0.1)" })

            let grid = MovieCollectionQuery.gridDescriptor(for: .recentlyAdded, scope: rails)
            #expect(grid.fetchLimit == recentlyAddedFetchLimit)
            #expect(try context.fetchCount(grid) == 6)
        }
    }

    @Test func `combined favorites and watched rails return only member rows`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertRailCatalog(in: context)

            for kind in [LibraryCollection.Kind.favorites, .recentlyWatched] {
                let movies = try context.fetch(MovieCollectionQuery.rowDescriptor(for: kind, scope: rails))
                let series = try context.fetch(SeriesCollectionQuery.rowDescriptor(for: kind, scope: rails))

                #expect(movies.count == 2)
                #expect(movies.allSatisfy { isMember($0.id) })
                #expect(series.count == 2)
                #expect(series.allSatisfy { isMember($0.id) })
            }
        }
    }

    @Test func `an isolated rail keeps the inline prefix and its rows`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertRailCatalog(in: context)
            let prefix = "\(first.uuidString)-"
            let isolated = MovieCollectionQuery.rowDescriptor(for: .recentlyAdded, scope: .isolated(first))
            let today = FetchDescriptor<Movie>(
                predicate: #Predicate { $0.added != nil && $0.id.starts(with: prefix) },
                sortBy: [SortDescriptor(\.added, comparator: .lexical, order: .reverse), SortDescriptor(\.num)]
            )

            #expect(try !String(describing: type(of: #require(isolated.predicate).expression)).contains("Evaluate"))
            #expect(try String(describing: type(of: #require(MovieCollectionQuery.rowDescriptor(
                for: .recentlyAdded, scope: rails
            ).predicate).expression)).contains("Evaluate"))
            #expect(try context.fetch(isolated).map(\.id) == context.fetch(today).map(\.id))
        }
    }
}

// MARK: - Category grids

extension CatalogScopeShapeTests {
    /// Two movie categories per playlist plus a series one; the outsider's sort
    /// first, so a leak heads the previews.
    private func insertCategories(in context: ModelContext) throws {
        for (playlist, sortBase) in [(outsider, 0), (first, 10), (second, 20)] {
            for (index, typeRaw) in ["vod", "vod", "series"].enumerated() {
                let category = Lume.Category(apiId: "\(index)", name: "Category \(index)", parentId: 0, typeRaw: typeRaw)
                category.id = "\(playlist.uuidString)-\(typeRaw)-cat-\(index)"
                category.sortOrder = sortBase + index
                context.insert(category)
            }
        }
        try context.save()
    }

    @Test func `combined category predicate returns member categories in SQL`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertCategories(in: context)
            let scoped = rails.categoryPredicate(for: .movies)
            let isolated = CatalogScope.isolated(first).categoryPredicate(for: .movies)

            let categories = try context.fetch(FetchDescriptor<Lume.Category>(
                predicate: #Predicate { $0.typeRaw == "vod" && $0.isHidden == false && scoped.evaluate($0) }
            ))

            #expect(categories.count == 4)
            #expect(categories.allSatisfy { isMember($0.id) })
            #expect(!String(describing: type(of: isolated.expression)).contains("Evaluate"))
            #expect(try context.fetchCount(FetchDescriptor(predicate: isolated)) == 3)
            #expect(try context.fetchCount(FetchDescriptor(predicate: CatalogScope.empty.categoryPredicate(for: .movies))) == 0)
        }
    }

    /// The browse screens' fetch (`MoviesView`'s `@Query`) grouped by member:
    /// priority order, never the outsider's, and one category's content fetch
    /// stays inside its playlist.
    @Test func `category grids follow member priority`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertCategories(in: context)
            try insertRailCatalog(in: context)
            let fetched = try context.fetch(FetchDescriptor<Lume.Category>(
                predicate: #Predicate { $0.typeRaw == "vod" && $0.isHidden == false }
            ))

            let layout = LibraryCategoryLayout.make(
                categories: fetched,
                members: rails.members(for: .movies).map { (id: $0, name: $0 == first ? "A" : "B") },
                sort: .playlist,
                restriction: ContentRestriction(),
                previewLimit: 3
            )

            #expect(layout.previews.map(\.id) == [
                "\(second.uuidString)-vod-cat-0", "\(second.uuidString)-vod-cat-1", "\(first.uuidString)-vod-cat-0"
            ])
            #expect(layout.remaining.map(\.id) == [first])
            #expect(layout.remaining.map(\.title) == ["A"])

            let categoryId = "\(second.uuidString)-vod-cat-0"
            let content = try context.fetch(FetchDescriptor<Movie>(
                predicate: #Predicate { $0.categoryId == categoryId },
                sortBy: ContentSortOption.playlist.movieDescriptors
            ))
            #expect(content.map(\.id) == ["\(second.uuidString)-vod-0", "\(second.uuidString)-vod-2"])
        }
    }
}

// MARK: - Live TV

extension CatalogScopeShapeTests {
    /// `second` is priority 1, as for the rails.
    private var liveMembers: CatalogScope {
        .combined([(id: second, tabs: [.liveTV]), (id: first, tabs: [.liveTV])])
    }

    private func liveID(_ playlist: UUID, _ index: Int) -> String {
        "\(playlist.uuidString)-live-\(index)"
    }

    private func liveCategory(_ playlist: UUID) -> String {
        "\(playlist.uuidString)-live-cat"
    }

    /// Three channels per playlist in its own category: 0 and 1 favorited and
    /// watched, 2 hidden. `favoriteOrder` interleaves the members with the
    /// outsider ahead of both, so a leaking scope heads every list.
    private func insertLiveCatalog(in context: ModelContext) throws {
        for (rank, playlist) in [outsider, first, second].enumerated() {
            for index in 0 ..< 3 {
                let stream = LiveStream(id: liveID(playlist, index), streamId: index, name: "Channel \(rank)-\(index)",
                                        num: index, categoryId: liveCategory(playlist))
                stream.lastWatchedDate = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + rank * 10 + index))
                if index < 2 {
                    stream.isFavorite = true
                    stream.favoriteOrder = index * 3 + rank
                } else {
                    stream.isHidden = true
                }
                context.insert(stream)
            }
        }
        try context.save()
    }

    private func clearMemberCollections(in context: ModelContext) throws {
        let prefix = "\(outsider.uuidString)-"
        for stream in try context.fetch(FetchDescriptor<LiveStream>(predicate: #Predicate { !$0.id.starts(with: prefix) })) {
            stream.isFavorite = false
            stream.lastWatchedDate = nil
        }
        try context.save()
    }

    /// The surf ring as `LiveChannelNavigator` reads it: a count, then one row
    /// per position.
    private func ring(
        _ scope: LiveChannelScope,
        in catalogScope: CatalogScope,
        restriction: ContentRestriction = ContentRestriction(),
        admitting admitted: String? = nil,
        context: ModelContext
    ) throws -> [String] {
        let descriptor = LiveChannelNavigator.scopeDescriptor(
            scope: scope, sort: .playlist, catalogScope: catalogScope,
            restriction: restriction, admittingHidden: admitted
        )
        let count = try context.fetchCount(descriptor)
        return try (0 ..< count).compactMap { position in
            try context.fetch(LiveChannelNavigator.positionDescriptor(descriptor, at: position)).first?.id
        }
    }

    // MARK: Probes

    @Test func `combined live probes are unsorted LIMIT 1 member reads`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertLiveCatalog(in: context)
            let restriction = ContentRestriction()
            let probes = [
                LiveChannelQuery.favoritesProbe(catalogScope: liveMembers, restriction: restriction),
                LiveChannelQuery.recentlyWatchedProbe(catalogScope: liveMembers, restriction: restriction)
            ]

            for probe in probes {
                #expect(probe.fetchLimit == 1)
                #expect(probe.sortBy.isEmpty)
                #expect(try String(describing: type(of: #require(probe.predicate).expression)).contains("Evaluate"))
                let rows = try context.fetch(probe)
                #expect(rows.count == 1)
                #expect(rows.allSatisfy { isMember($0.id) })
            }
        }
    }

    @Test func `combined live probes miss a non members collections`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertLiveCatalog(in: context)
            try clearMemberCollections(in: context)
            let restriction = ContentRestriction()

            #expect(try context.fetchCount(LiveChannelQuery.favoritesProbe(catalogScope: liveMembers, restriction: restriction)) == 0)
            #expect(try context.fetchCount(LiveChannelQuery.recentlyWatchedProbe(
                catalogScope: liveMembers, restriction: restriction
            )) == 0)
            #expect(try context.fetchCount(LiveChannelQuery.favoritesProbe(
                catalogScope: .isolated(outsider), restriction: restriction
            )) == 1)
        }
    }

    @Test func `combined live probes keep the restriction in SQL`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertLiveCatalog(in: context)
            let both = ContentRestriction(hiddenCategoryIDs: [liveCategory(first), liveCategory(second)])
            let onlyFirst = ContentRestriction(hiddenCategoryIDs: [liveCategory(first)])

            #expect(try context.fetchCount(LiveChannelQuery.favoritesProbe(catalogScope: liveMembers, restriction: both)) == 0)
            #expect(try context.fetchCount(LiveChannelQuery.recentlyWatchedProbe(catalogScope: liveMembers, restriction: both)) == 0)
            let row = try context.fetch(LiveChannelQuery.favoritesProbe(catalogScope: liveMembers, restriction: onlyFirst))
            #expect(row.map(\.categoryId) == [liveCategory(second)])
        }
    }

    @Test func `isolated live probes keep the inline prefix`() throws {
        let restriction = ContentRestriction()
        for probe in [
            LiveChannelQuery.favoritesProbe(catalogScope: .isolated(first), restriction: restriction),
            LiveChannelQuery.recentlyWatchedProbe(catalogScope: .isolated(first), restriction: restriction)
        ] {
            #expect(try !String(describing: type(of: #require(probe.predicate).expression)).contains("Evaluate"))
        }
    }

    // MARK: Surf ring

    @Test func `a combined favorites ring reads every member position in SQL`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertLiveCatalog(in: context)

            #expect(try ring(.favorites, in: liveMembers, context: context) == [
                liveID(first, 0), liveID(second, 0), liveID(first, 1), liveID(second, 1)
            ])
            #expect(try ring(.recentlyWatched, in: liveMembers, context: context) == [
                liveID(second, 1), liveID(second, 0), liveID(first, 1), liveID(first, 0)
            ])
        }
    }

    @Test func `a combined ring keeps the restriction in SQL`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertLiveCatalog(in: context)
            let restriction = ContentRestriction(hiddenCategoryIDs: [liveCategory(first)])

            #expect(try ring(.favorites, in: liveMembers, restriction: restriction, context: context) == [
                liveID(second, 0), liveID(second, 1)
            ])
        }
    }

    @Test func `a category ring under a combined scope stays in its playlist`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertLiveCatalog(in: context)
            let category = LiveChannelScope.category(liveCategory(first))

            #expect(try ring(category, in: liveMembers, context: context) == [liveID(first, 0), liveID(first, 1)])
            #expect(try ring(category, in: liveMembers, admitting: liveID(first, 2), context: context) == [
                liveID(first, 0), liveID(first, 1), liveID(first, 2)
            ])
        }
    }

    @Test func `an isolated ring keeps the inline prefix and its rows`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertLiveCatalog(in: context)
            let isolated = LiveChannelNavigator.scopeDescriptor(
                scope: .favorites, sort: .playlist, catalogScope: .isolated(first),
                restriction: ContentRestriction(), admittingHidden: nil
            )

            #expect(try !String(describing: type(of: #require(isolated.predicate).expression)).contains("Evaluate"))
            #expect(try ring(.favorites, in: .isolated(first), context: context) == [liveID(first, 0), liveID(first, 1)])
        }
    }
}

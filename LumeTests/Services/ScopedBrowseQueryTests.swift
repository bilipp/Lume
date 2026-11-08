//
//  ScopedBrowseQueryTests.swift
//  LumeTests
//
//  The Movies/Series collection rails, the genre grids and the genre derivation
//  read through a `CatalogScope`. Isolated mode is the default, so its rails
//  must keep the exact inline `id.starts(with:)` predicate; a combined scope
//  has to stay in SQL, which only an on-disk store proves (an in-memory one
//  evaluates predicates in Swift and would hide a composition CoreData cannot
//  render).
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct ScopedBrowseQueryTests {
    private let first = UUID()
    private let second = UUID()
    /// A member that contributes only Live TV: its movies and series must stay out.
    private let liveOnly = UUID()
    private let outsider = UUID()

    private var combined: CatalogScope {
        .combined([
            (id: first, tabs: [.movies, .series]),
            (id: second, tabs: [.movies, .series, .liveTV]),
            (id: liveOnly, tabs: [.liveTV])
        ])
    }

    private static let kinds: [LibraryCollection.Kind] = [.recentlyWatched, .favorites, .recentlyAdded]

    private func expressionType(_ predicate: Predicate<some PersistentModel>?) -> String {
        predicate.map { String(describing: type(of: $0.expression)) } ?? ""
    }

    /// Every playlist gets `count` favorited, watched, dated titles. Stamps
    /// interleave across `first` and `second`, and the non-members' are the
    /// newest, so a leaking scope tops every rail.
    private func insertCatalog(in context: ModelContext) throws {
        for (playlist, offset) in [(first, 0), (second, 1), (liveOnly, 100), (outsider, 200)] {
            let prefix = playlist.uuidString
            for index in 0 ..< 3 {
                let stamp = String(1_700_000_000 + offset + index * 2)
                let movie = Movie(id: "\(prefix)-vod-\(index)", streamId: index, name: "Movie \(index)", added: stamp)
                movie.genre = playlist == outsider ? "Horror" : (playlist == first ? "Action" : "Comedy")
                movie.isFavorite = true
                movie.lastWatchedDate = Date()
                context.insert(movie)

                let series = Series(
                    id: "\(prefix)-series-\(index)",
                    seriesId: index,
                    name: "Show \(index)",
                    genre: playlist == first ? "Drama" : "Western",
                    lastModified: stamp
                )
                series.isFavorite = true
                series.lastWatchedDate = Date()
                context.insert(series)
            }
        }
        try context.save()
    }

    // MARK: - Isolated mode keeps today's predicate

    @Test func `isolated collection rails inline the prefix with no evaluate node`() {
        let scope = CatalogScope.isolated(first)
        let prefix = "\(first.uuidString)-"
        let today = #Predicate<Movie> { $0.isFavorite && $0.id.starts(with: prefix) }

        let favorites = MovieCollectionQuery.rowDescriptor(for: .favorites, scope: scope)
        #expect(expressionType(favorites.predicate) == expressionType(today))
        for kind in Self.kinds {
            #expect(!expressionType(MovieCollectionQuery.rowDescriptor(for: kind, scope: scope).predicate).contains("Evaluate"))
            #expect(!expressionType(SeriesCollectionQuery.rowDescriptor(for: kind, scope: scope).predicate).contains("Evaluate"))
        }
    }

    /// A combined scope where only one member contributes the type is the
    /// isolated predicate for that tab.
    @Test func `a single contributing member inlines the prefix too`() {
        let scope = CatalogScope.combined([(id: first, tabs: [.movies]), (id: second, tabs: [.liveTV])])
        #expect(!expressionType(MovieCollectionQuery.rowDescriptor(for: .recentlyAdded, scope: scope).predicate).contains("Evaluate"))
    }

    @Test func `combined rails keep their bounds`() {
        for kind in Self.kinds {
            #expect(MovieCollectionQuery.rowDescriptor(for: kind, scope: combined).fetchLimit == collectionRowFetchLimit)
            #expect(SeriesCollectionQuery.rowDescriptor(for: kind, scope: combined).fetchLimit == collectionRowFetchLimit)
            #expect(expressionType(MovieCollectionQuery.rowDescriptor(for: kind, scope: combined).predicate).contains("Evaluate"))
        }
        #expect(MovieCollectionQuery.gridDescriptor(for: .recentlyAdded, scope: combined).fetchLimit == recentlyAddedFetchLimit)
        #expect(SeriesCollectionQuery.gridDescriptor(for: .favorites, scope: combined).fetchLimit == nil)
    }

    // MARK: - Combined rails stay in SQL

    @Test func `combined rails fetch only contributing members`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertCatalog(in: context)
            let members = ["\(first.uuidString)-", "\(second.uuidString)-"]

            for kind in Self.kinds {
                let movies = try context.fetch(MovieCollectionQuery.rowDescriptor(for: kind, scope: combined))
                #expect(movies.count == 6, "\(kind) movies")
                #expect(movies.allSatisfy { movie in members.contains { movie.id.hasPrefix($0) } })

                let series = try context.fetch(SeriesCollectionQuery.gridDescriptor(for: kind, scope: combined))
                #expect(series.count == 6, "\(kind) series")
                #expect(series.allSatisfy { show in members.contains { show.id.hasPrefix($0) } })
            }
        }
    }

    @Test func `combined recently added interleaves members newest first`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertCatalog(in: context)
            let rows = try context.fetch(MovieCollectionQuery.rowDescriptor(for: .recentlyAdded, scope: combined))
            let (one, two) = (first.uuidString, second.uuidString)
            #expect(rows.map(\.id) == [
                "\(two)-vod-2", "\(one)-vod-2", "\(two)-vod-1", "\(one)-vod-1", "\(two)-vod-0", "\(one)-vod-0"
            ])
        }
    }

    @Test func `the empty scope's rails fetch nothing`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertCatalog(in: context)
            for kind in Self.kinds {
                #expect(try context.fetch(MovieCollectionQuery.rowDescriptor(for: kind, scope: .empty)).isEmpty)
                #expect(try context.fetch(SeriesCollectionQuery.rowDescriptor(for: kind, scope: .empty)).isEmpty)
            }
        }
    }

    // MARK: - Genres

    @Test func `a combined genre page fetches only contributing members`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertCatalog(in: context)
            let request = { (genre: String, scope: CatalogScope) in
                GenrePageRequest(genre: genre, scope: scope, excludedCategoryIDs: [], offset: 0, pageSize: 50)
            }

            let action = GenrePageFetcher.movies(container: context.container, request: request("Action", combined), sortBy: [])
            #expect(action.ids.count == 3)
            let comedy = GenrePageFetcher.movies(container: context.container, request: request("Comedy", combined), sortBy: [])
            #expect(comedy.ids.count == 3, "the live-only member's comedies stay out")
            let horror = GenrePageFetcher.movies(container: context.container, request: request("Horror", combined), sortBy: [])
            #expect(horror.ids.isEmpty)
            let isolated = GenrePageFetcher.movies(container: context.container, request: request("Comedy", .isolated(first)), sortBy: [])
            #expect(isolated.ids.isEmpty)

            let western = GenrePageFetcher.series(container: context.container, request: request("Western", combined), sortBy: [])
            #expect(western.ids.count == 3)
        }
    }

    @Test func `combined genre derivation unions contributing members`() async throws {
        let container = try makeTestContainer()
        try insertCatalog(in: container.mainContext)

        let movies = await GenreDerivation.movieGenres(in: container, scope: combined, restriction: ContentRestriction())
        #expect(Set(movies) == ["Action", "Comedy"])
        let series = await GenreDerivation.seriesGenres(in: container, scope: combined, restriction: ContentRestriction())
        #expect(Set(series) == ["Drama", "Western"])
        let none = await GenreDerivation.movieGenres(in: container, scope: .empty, restriction: ContentRestriction())
        #expect(none.isEmpty)
    }
}

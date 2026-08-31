//
//  SearchPredicateTests.swift
//  LumeTests
//
//  Search excludes hidden/restricted categories inside the fetch, so the
//  per-type result limit isn't spent on rows the viewer will never see, and
//  splits that limit between playlists when searching across them. The
//  predicates must run against an on-disk SQLite store: in-memory stores
//  evaluate predicates without SQL generation, so a form CoreData can't render
//  passes there and traps on device (see `TmdbIdPredicateTests`).
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SearchPredicateTests {
    /// The container must be held for the test's duration — a
    /// `makeSQLiteContainer().mainContext` temporary deallocates the store out
    /// from under the context and traps inside SwiftData on the first save.
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

    private func scope(query: String, excluded: Set<String> = []) -> SearchScope {
        SearchScope(query: query, playlistID: "", restrictToPlaylist: false, excluded: excluded)
    }

    private func insertMovies(_ context: ModelContext) throws {
        for (id, category) in [("m1", "en"), ("m2", "nl")] {
            let movie = Movie(id: id, streamId: 1, name: "The Matrix")
            movie.categoryId = category
            context.insert(movie)
        }
        // An uncategorised title — m3u sources don't always supply a category.
        let orphan = Movie(id: "m3", streamId: 3, name: "The Matrix")
        context.insert(orphan)
        try context.save()
    }

    @Test func `movie search drops excluded categories and keeps uncategorised titles`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        try insertMovies(context)

        let fetched = try context.fetch(
            FetchDescriptor<Movie>(predicate: searchMoviePredicate(scope: scope(query: "matrix", excluded: ["nl"])))
        )
        #expect(Set(fetched.map(\.id)) == ["m1", "m3"])
    }

    @Test func `movie search returns everything when nothing is excluded`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        try insertMovies(context)

        let fetched = try context.fetch(
            FetchDescriptor<Movie>(predicate: searchMoviePredicate(scope: scope(query: "matrix")))
        )
        #expect(Set(fetched.map(\.id)) == ["m1", "m2", "m3"])
    }

    @Test func `series search drops excluded categories`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        let visible = Series(id: "s1", seriesId: 1, name: "Dark Matter")
        visible.categoryId = "en"
        let hidden = Series(id: "s2", seriesId: 2, name: "Dark Matter")
        hidden.categoryId = "nl"
        context.insert(visible)
        context.insert(hidden)
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<Series>(predicate: searchSeriesPredicate(scope: scope(query: "dark", excluded: ["nl"])))
        )
        #expect(fetched.map(\.id) == ["s1"])
    }

    @Test func `live search drops excluded categories and individually hidden channels`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        let visible = LiveStream(id: "l1", streamId: 1, name: "News One")
        visible.categoryId = "en"
        let inHiddenCategory = LiveStream(id: "l2", streamId: 2, name: "News Two")
        inHiddenCategory.categoryId = "nl"
        let hiddenChannel = LiveStream(id: "l3", streamId: 3, name: "News Three")
        hiddenChannel.categoryId = "en"
        hiddenChannel.isHidden = true
        for stream in [visible, inHiddenCategory, hiddenChannel] {
            context.insert(stream)
        }
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<LiveStream>(
                predicate: searchLiveStreamPredicate(scope: scope(query: "news", excluded: ["nl"]))
            )
        )
        #expect(fetched.map(\.id) == ["l1"])
    }

    @Test func `playlist scoping still applies alongside the exclusion`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        let mine = Movie(id: "m1", streamId: 1, name: "The Matrix")
        mine.categoryId = "PL-A-vod-1"
        let other = Movie(id: "m2", streamId: 2, name: "The Matrix")
        other.categoryId = "PL-B-vod-1"
        context.insert(mine)
        context.insert(other)
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<Movie>(predicate: searchMoviePredicate(scope: SearchScope(
                query: "matrix", playlistID: "PL-A", restrictToPlaylist: true, excluded: ["nl"]
            )))
        )
        #expect(fetched.map(\.id) == ["m1"])
    }

    // MARK: - Cross-playlist budget

    /// Two playlists, one of which alone can fill the whole budget with titles
    /// that sort first. The other must still be represented — a single catalog
    /// crowding the rest out is indistinguishable, on screen, from the setting
    /// not working at all.
    private func insertTwoCatalogs(_ context: ModelContext, limit: Int) throws -> (String, String) {
        let big = UUID().uuidString
        let small = UUID().uuidString
        for index in 0 ..< (limit + 10) {
            let movie = Movie(id: "\(big)-movie-\(index)", streamId: index, name: "Aaa Matrix \(index)")
            movie.categoryId = "\(big)-vod-1"
            context.insert(movie)
        }
        for index in 0 ..< 2 {
            let movie = Movie(id: "\(small)-movie-\(index)", streamId: index, name: "Zzz Matrix \(index)")
            movie.categoryId = "\(small)-vod-1"
            context.insert(movie)
        }
        try context.save()
        return (big, small)
    }

    private func names(_ ids: [PersistentIdentifier], in context: ModelContext) -> [String] {
        ids.compactMap { (context.model(for: $0) as? Movie)?.name }
    }

    @Test func `each playlist gets a share of the result budget`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        let limit = 20
        let (big, small) = try insertTwoCatalogs(context, limit: limit)

        let hits = SearchFetcher.fetch(container: container, request: SearchRequest(
            query: "matrix", playlistIDs: [big, small],
            wantMovies: true, wantSeries: false, wantLive: false,
            excludedCategoryIDs: [], limit: limit
        ))

        #expect(hits.movies.count == limit)
        let matched = names(hits.movies, in: context)
        #expect(matched.contains { $0.hasPrefix("Zzz") })
        #expect(matched.filter { $0.hasPrefix("Aaa") }.count == limit - 2)
    }

    @Test func `results stay in name order after the split`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        let limit = 20
        let (big, small) = try insertTwoCatalogs(context, limit: limit)

        let hits = SearchFetcher.fetch(container: container, request: SearchRequest(
            query: "matrix", playlistIDs: [big, small],
            wantMovies: true, wantSeries: false, wantLive: false,
            excludedCategoryIDs: [], limit: limit
        ))

        let matched = names(hits.movies, in: context)
        #expect(matched == matched.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func `a split search still finds uncategorised titles`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        let (big, small) = try insertTwoCatalogs(context, limit: 5)
        // m3u sources don't always supply a category, and a per-playlist fetch
        // keys off the playlist UUID prefixed onto the category id.
        context.insert(Movie(id: "orphan", streamId: 999, name: "Bbb Matrix"))
        try context.save()

        let hits = SearchFetcher.fetch(container: container, request: SearchRequest(
            query: "matrix", playlistIDs: [big, small],
            wantMovies: true, wantSeries: false, wantLive: false,
            excludedCategoryIDs: [], limit: 20
        ))

        #expect(names(hits.movies, in: context).contains("Bbb Matrix"))
    }

    @Test func `a single playlist search is unchanged`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        let (big, _) = try insertTwoCatalogs(context, limit: 5)

        let hits = SearchFetcher.fetch(container: container, request: SearchRequest(
            query: "matrix", playlistIDs: [big],
            wantMovies: true, wantSeries: false, wantLive: false,
            excludedCategoryIDs: [], limit: 20
        ))

        #expect(hits.movies.count == 15)
        #expect(names(hits.movies, in: context).allSatisfy { $0.hasPrefix("Aaa") })
    }
}

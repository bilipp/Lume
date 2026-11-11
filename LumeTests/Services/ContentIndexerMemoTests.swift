//
//  ContentIndexerMemoTests.swift
//  LumeTests
//
//  Duplicate rows of one title (qualities, languages, playlists) cost one TMDB
//  search and one details request per pass: the indexer memoises both and
//  writes the result to every sibling in the same chunk.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.serialized)
struct ContentIndexerMemoTests {
    private static let host = "api.themoviedb.org"

    /// On disk, so the sibling predicates go through SQL generation.
    private func withContainer(_ body: (ModelContainer) async throws -> Void) async throws {
        let schema = OnDiskCatalogStore.catalogSchema
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(
            schema: schema,
            url: directory.appendingPathComponent("memo.store"),
            cloudKitDatabase: .none
        )
        try await body(ModelContainer(for: schema, configurations: configuration))
    }

    private func makeIndexer(container: ModelContainer) -> ContentIndexer {
        StubURLProtocol.register(host: Self.host) { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/3/search/") {
                return .init(body: #"{"results":[{"id":603}]}"#)
            }
            return .init(body: #"{"overview":"A hacker learns the truth.","genres":[{"name":"Sci-Fi"}]}"#)
        }
        let client = TMDBClient(session: StubURLProtocol.makeSession(), token: "test-token", language: "en-US")
        return ContentIndexer(modelContainer: container, tmdbClient: client)
    }

    private func requests(matching prefix: String) -> Int {
        StubURLProtocol.requests(host: Self.host).count { ($0.url?.path ?? "").hasPrefix(prefix) }
    }

    @Test func `four duplicate movies cost one search and one details request`() async throws {
        try await withContainer { container in
            let context = container.mainContext
            let names = ["The Matrix (1999) 4K", "DE - The Matrix (1999)", "The Matrix (1999) FHD", "EN | The Matrix 1999"]
            for (index, name) in names.enumerated() {
                let movie = Movie(id: "m\(index)", streamId: index, name: name, categoryId: "c\(index % 2)")
                movie.titleGroupKey = TitleGroupKey.movie(tmdbId: nil, name: name)
                context.insert(movie)
            }
            try context.save()

            let indexer = makeIndexer(container: container)
            let processed = try await indexer.indexNextChunk(embedder: nil)

            #expect(processed == 4)
            #expect(requests(matching: "/3/search/movie") == 1)
            #expect(requests(matching: "/3/movie/603") == 1)

            let movies = try ModelContext(container).fetch(FetchDescriptor<Movie>())
            #expect(movies.count == 4)
            for movie in movies {
                #expect(movie.tmdbId == 603)
                #expect(movie.titleGroupKey == "tmdb:603")
                #expect(movie.indexedAt != nil)
                #expect(movie.plot == "A hacker learns the truth.")
            }
            // One primary per (category, key) group.
            for category in ["c0", "c1"] {
                #expect(movies.count { $0.categoryId == category && $0.isCategoryGroupPrimary } == 1)
            }
        }
    }

    @Test func `duplicate series share one search and one details request`() async throws {
        try await withContainer { container in
            let context = container.mainContext
            for (index, name) in ["Dark (2017) 4K", "DE - Dark (2017)"].enumerated() {
                let series = Series(id: "s\(index)", seriesId: index, name: name)
                series.titleGroupKey = TitleGroupKey.series(tmdbId: nil, name: name)
                context.insert(series)
            }
            try context.save()

            let indexer = makeIndexer(container: container)
            _ = try await indexer.indexNextChunk(embedder: nil)

            #expect(requests(matching: "/3/search/tv") == 1)
            #expect(requests(matching: "/3/tv/603") == 1)
            let series = try ModelContext(container).fetch(FetchDescriptor<Series>())
            #expect(series.allSatisfy { $0.tmdbId == 603 && $0.titleGroupKey == "tmdb:603" && $0.indexedAt != nil })
        }
    }

    @Test func `a row that adopted a tmdb group is indexed without a search of its own`() async throws {
        try await withContainer { container in
            let context = container.mainContext
            let carrier = Movie(id: "x1", streamId: 1, name: "The Matrix (1999)", categoryId: "c0")
            carrier.tmdbId = 603
            TitleGroupPrimaries.assignKey(to: carrier)
            let adopter = Movie(id: "m1", streamId: 2, name: "The Matrix (1999) FHD", categoryId: "c1")
            TitleGroupPrimaries.assignKey(to: adopter)
            context.insert(carrier)
            context.insert(adopter)
            TitleGroupPrimaries.recompute(
                categoryKeys: .init(movies: TitleGroupPrimaries.categoryKeys(of: [carrier, adopter])),
                in: context,
                preferredLanguages: []
            )
            try context.save()
            #expect(adopter.titleGroupKey == "tmdb:603")

            let indexer = makeIndexer(container: container)
            _ = try await indexer.indexNextChunk(embedder: nil)

            #expect(requests(matching: "/3/search/") == 0)
            #expect(requests(matching: "/3/movie/603") == 1)
            let stored = try #require(Movie.row(id: "m1", in: ModelContext(container)))
            #expect(stored.tmdbId == nil)
            #expect(stored.titleGroupKey == "tmdb:603")
            #expect(stored.indexedAt != nil)
        }
    }
}

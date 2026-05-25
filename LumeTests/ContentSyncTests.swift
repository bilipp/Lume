//
//  ContentSyncTests.swift
//  LumeTests
//
//  Tests that content sync processes large datasets with bounded memory and speed.
//

import Testing
import Foundation
import SwiftData
@testable import Lume

struct ContentSyncTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self,
            Category.self,
            LiveStream.self,
            Movie.self,
            Series.self,
            Episode.self,
            EPGListing.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func exampleMoviesURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleData/Movies.json")
    }

    /// Verifies that syncing 13,900 movies completes in a reasonable time
    /// and results in the correct number of persisted records.
    @Test func syncMoviesFromExampleJSON() async throws {
        let data = try Data(contentsOf: exampleMoviesURL())
        let movies = try JSONDecoder().decode([XtreamVODStream].self, from: data)
        #expect(movies.count > 10000, "Expected at least 10,000 movies in example data, got \(movies.count)")

        let container = try makeContainer()

        // Create a playlist
        let setupContext = ModelContext(container)
        let playlist = Playlist(name: "Test", serverURL: "http://test.example.com", username: "user", password: "pass")
        setupContext.insert(playlist)
        try setupContext.save()
        let playlistId = playlist.id

        let batchSize = 2000
        let totalCount = movies.count

        let start = ContinuousClock.now

        // Process in batches — same logic as ContentSyncManager
        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            try autoreleasepool {
                let batchEnd = min(batchStart + batchSize, totalCount)
                let batch = movies[batchStart..<batchEnd]

                let context = ModelContext(container)
                context.autosaveEnabled = false

                for movieDTO in batch {
                    guard let streamId = movieDTO.streamId else { continue }
                    let movieId = "\(playlistId.uuidString)-movie-\(streamId)"

                    let movie = Movie(id: movieId, streamId: streamId, name: "")
                    movie.name = movieDTO.name ?? ""
                    movie.streamIcon = movieDTO.streamIcon
                    movie.rating = movieDTO.rating ?? 0
                    movie.rating5Based = movieDTO.rating5Based ?? 0
                    movie.added = movieDTO.added
                    movie.containerExtension = movieDTO.containerExtension
                    movie.tmdb = movieDTO.tmdb
                    movie.num = movieDTO.num ?? 0
                    movie.isAdult = movieDTO.isAdult ?? 0

                    // Foreign key — same shape as ContentSyncManager produces.
                    if let catIdStr = movieDTO.categoryId {
                        movie.categoryId = "\(playlistId.uuidString)-vod-\(catIdStr)"
                    }

                    if let tmdbString = movieDTO.tmdb, let tmdbInt = Int(tmdbString) {
                        movie.tmdbId = tmdbInt
                    }

                    context.insert(movie)
                }

                try context.save()
            }
        }

        let elapsed = ContinuousClock.now - start

        // Verify all movies were persisted
        let verifyContext = ModelContext(container)
        let count = try verifyContext.fetchCount(FetchDescriptor<Movie>())
        #expect(count == movies.count, "Expected \(movies.count) movies in database, got \(count)")

        // Should complete well under 30 seconds for 13,900 movies
        let seconds = elapsed.components.seconds
        #expect(seconds < 30, "Sync took \(seconds)s — expected < 30s for \(movies.count) movies")
    }

    /// Verifies that upsert via @Attribute(.unique) doesn't create duplicates.
    @Test func syncMoviesUpsertDoesNotDuplicate() async throws {
        let container = try makeContainer()
        let playlistId = UUID()

        // Insert 100 movies
        let ctx1 = ModelContext(container)
        ctx1.autosaveEnabled = false
        for i in 0..<100 {
            let movie = Movie(id: "\(playlistId)-movie-\(i)", streamId: i, name: "Movie \(i)")
            ctx1.insert(movie)
        }
        try ctx1.save()

        // Re-insert the same 100 movies with updated names (upsert)
        let ctx2 = ModelContext(container)
        ctx2.autosaveEnabled = false
        for i in 0..<100 {
            let movie = Movie(id: "\(playlistId)-movie-\(i)", streamId: i, name: "Updated Movie \(i)")
            ctx2.insert(movie)
        }
        try ctx2.save()

        // Verify count is still 100 (no duplicates)
        let verifyContext = ModelContext(container)
        let count = try verifyContext.fetchCount(FetchDescriptor<Movie>())
        #expect(count == 100, "Expected 100 movies after upsert, got \(count)")
    }
}

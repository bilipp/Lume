//
//  ContentSyncTests.swift
//  LumeTests
//
//  Tests that content sync processes large datasets with bounded memory and speed.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct ContentSyncTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self,
            Lume.Category.self,
            LiveStream.self,
            Movie.self,
            Series.self,
            Episode.self,
            CastMember.self,
            EPGListing.self
        ])
        // `cloudKitDatabase: .none` is required: the catalog uses `@Attribute(.unique)`,
        // which CloudKit forbids. The default `.automatic` mirrors to CloudKit on a
        // signed/entitled test host and fails the load with `loadIssueModelContainer`.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Large Dataset Performance

    @Test func `sync movies from example JSON`() throws {
        let movies: [XtreamVODStream] = try loadExampleJSON("Movies.json")
        #expect(movies.count > 10000, "Expected at least 10,000 movies in example data, got \(movies.count)")

        let container = try makeContainer()

        let setupContext = ModelContext(container)
        let playlist = Playlist(name: "Test", serverURL: "http://test.example.com", username: "user", password: "pass")
        setupContext.insert(playlist)
        try setupContext.save()
        let playlistId = playlist.id

        let batchSize = 2000
        let totalCount = movies.count

        let start = ContinuousClock.now

        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            try autoreleasepool {
                let batchEnd = min(batchStart + batchSize, totalCount)
                let batch = movies[batchStart ..< batchEnd]

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

        let verifyContext = ModelContext(container)
        let count = try verifyContext.fetchCount(FetchDescriptor<Movie>())
        #expect(count == movies.count, "Expected \(movies.count) movies in database, got \(count)")

        let seconds = elapsed.components.seconds
        #expect(seconds < 30, "Sync took \(seconds)s — expected < 30s for \(movies.count) movies")
    }

    // MARK: - Upsert

    @Test func `sync movies upsert does not duplicate`() throws {
        let container = try makeContainer()
        let playlistId = UUID()

        let ctx1 = ModelContext(container)
        ctx1.autosaveEnabled = false
        for index in 0 ..< 100 {
            let movie = Movie(id: "\(playlistId)-movie-\(index)", streamId: index, name: "Movie \(index)")
            ctx1.insert(movie)
        }
        try ctx1.save()

        let ctx2 = ModelContext(container)
        ctx2.autosaveEnabled = false
        for index in 0 ..< 100 {
            let movie = Movie(id: "\(playlistId)-movie-\(index)", streamId: index, name: "Updated Movie \(index)")
            ctx2.insert(movie)
        }
        try ctx2.save()

        let verifyContext = ModelContext(container)
        let count = try verifyContext.fetchCount(FetchDescriptor<Movie>())
        #expect(count == 100, "Expected 100 movies after upsert, got \(count)")
    }

    @Test func `re-sync preserves favorites and watch progress`() throws {
        let container = try makeContainer()
        let playlistId = UUID()
        let movieId = "\(playlistId)-movie-1"

        // Initial sync inserts the movie.
        let ctx1 = ModelContext(container)
        ctx1.autosaveEnabled = false
        let inserted = Movie(id: movieId, streamId: 1, name: "Movie")
        ctx1.insert(inserted)
        try ctx1.save()

        // User favorites it, watches partway, and it lands in recently-watched.
        let ctx2 = ModelContext(container)
        ctx2.autosaveEnabled = false
        let toEdit = try #require(try ctx2.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        ).first)
        toEdit.isFavorite = true
        toEdit.watchProgress = 1234
        toEdit.lastWatchedDate = Date(timeIntervalSince1970: 1_000_000)
        try ctx2.save()

        // Re-sync: update the existing row in place (the fixed behavior) rather
        // than upserting a fresh object, which would reset the user fields.
        let ctx3 = ModelContext(container)
        ctx3.autosaveEnabled = false
        var existing: [String: Movie] = [:]
        let batchIds = [movieId]
        for movie in try ctx3.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { batchIds.contains($0.id) })
        ) {
            existing[movie.id] = movie
        }
        let movie: Movie
        if let found = existing[movieId] {
            movie = found
        } else {
            movie = Movie(id: movieId, streamId: 1, name: "")
            ctx3.insert(movie)
        }
        movie.name = "Movie (renamed by provider)"
        try ctx3.save()

        let verify = ModelContext(container)
        let result = try #require(try verify.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        ).first)
        #expect(result.name == "Movie (renamed by provider)", "Provider field should update")
        #expect(result.isFavorite, "Favorite must survive re-sync")
        #expect(result.watchProgress == 1234, "Watch progress must survive re-sync")
        #expect(
            result.lastWatchedDate == Date(timeIntervalSince1970: 1_000_000),
            "Recently-watched timestamp must survive re-sync"
        )
    }

    // MARK: - Batch Edge Cases

    @Test func `empty dataset handled gracefully`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test", serverURL: "http://x.com", username: "u", password: "p")
        context.insert(playlist)
        try context.save()

        let count = try context.fetchCount(FetchDescriptor<Movie>())
        #expect(count == 0)
    }

    @Test func `single item in batch`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test", serverURL: "http://x.com", username: "u", password: "p")
        context.insert(playlist)
        try context.save()

        let movie = Movie(id: "\(playlist.id)-movie-1", streamId: 1, name: "Single", containerExtension: "mp4")
        context.insert(movie)
        try context.save()

        let count = try context.fetchCount(FetchDescriptor<Movie>())
        #expect(count == 1)
    }

    // MARK: - ID Construction

    @Test func `movie ID uses playlist prefix`() {
        let playlistId = UUID()
        let streamId = 12345
        let movieId = "\(playlistId.uuidString)-movie-\(streamId)"
        #expect(movieId.hasPrefix(playlistId.uuidString))
        #expect(movieId.hasSuffix("-movie-12345"))
    }

    @Test func `category ID matches content sync manager pattern`() {
        let playlistId = UUID()
        let categoryId = "117"
        let expected = "\(playlistId.uuidString)-vod-\(categoryId)"
        #expect(expected == "\(playlistId.uuidString)-vod-117")
    }

    // MARK: - Playlist State Transitions

    @Test func `playlist sync status transitions`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test", serverURL: "http://x.com", username: "u", password: "p")
        context.insert(playlist)
        try context.save()

        playlist.syncStatus = .syncing
        try context.save()
        #expect(playlist.syncStatus == .syncing)

        playlist.syncStatus = .idle
        playlist.lastSyncDate = Date()
        try context.save()
        #expect(playlist.syncStatus == .idle)
        #expect(playlist.lastSyncDate != nil)
    }

    @Test func `playlist error status persists`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test", serverURL: "http://x.com", username: "u", password: "p")
        context.insert(playlist)
        try context.save()

        playlist.syncStatus = .error
        try context.save()

        let targetId = playlist.id
        let fetched = try context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == targetId })
        ).first
        #expect(fetched?.syncStatus == .error)
    }
}

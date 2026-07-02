//
//  TmdbIdPredicateTests.swift
//  LumeTests
//
//  Regression coverage for the batched trending/watchlist catalog lookups.
//  The predicates must run against an on-disk SQLite store: the original
//  `ids.contains($0.tmdbId ?? -1)` form compiled to a ternary CoreData cannot
//  render as SQL and crashed at fetch time on device, while in-memory stores
//  evaluate predicates without SQL generation and never reproduce it.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct TmdbIdPredicateTests {
    /// On-disk store in a unique temp directory so predicate evaluation goes
    /// through CoreData's SQL generation (unlike `isStoredInMemoryOnly`).
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

    @Test func `movie tmdb id predicate generates SQL`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext

        let matching = Movie(id: "m1", streamId: 1, name: "Matching")
        matching.tmdbId = 42
        let other = Movie(id: "m2", streamId: 2, name: "Other")
        other.tmdbId = 7
        let unenriched = Movie(id: "m3", streamId: 3, name: "No TMDB id")
        context.insert(matching)
        context.insert(other)
        context.insert(unenriched)
        try context.save()

        let descriptor = FetchDescriptor<Movie>(predicate: movieTmdbIdPredicate(ids: [42, 99]))
        let fetched = try context.fetch(descriptor)
        #expect(fetched.map(\.tmdbId) == [42])
    }

    @Test func `series tmdb id predicate generates SQL`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext

        let matching = Series(id: "s1", seriesId: 1, name: "Matching")
        matching.tmdbId = 314
        let unenriched = Series(id: "s2", seriesId: 2, name: "No TMDB id")
        context.insert(matching)
        context.insert(unenriched)
        try context.save()

        let descriptor = FetchDescriptor<Series>(predicate: seriesTmdbIdPredicate(ids: [314]))
        let fetched = try context.fetch(descriptor)
        #expect(fetched.map(\.tmdbId) == [314])
    }
}

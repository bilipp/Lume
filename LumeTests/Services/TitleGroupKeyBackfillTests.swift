//
//  TitleGroupKeyBackfillTests.swift
//  LumeTests
//
//  The launch backfill of title group keys and category primaries. Runs on a
//  real store file, like `TitleGroupPrimariesTests`: the primaries fetch
//  matches optional columns with `IN`, which an in-memory store evaluates in
//  Swift instead of SQL.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct TitleGroupKeyBackfillTests {
    private static let category = "P-vod-1"

    private func withContainer<T>(_ body: (ModelContainer) async throws -> T) async throws -> T {
        let schema = OnDiskCatalogStore.catalogSchema
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(
            schema: schema,
            url: directory.appendingPathComponent("backfill.store"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        return try await body(container)
    }

    /// Rows as a store from before the columns existed holds them: no key, and
    /// every row flagged primary.
    private func insertLegacy(into container: ModelContainer) throws {
        let context = ModelContext(container)
        let movies: [(id: String, name: String, tmdbId: Int?)] = [
            ("m-1", "Inception (2010) FHD", nil),
            ("m-2", "Inception (2010) 4K", nil),
            ("m-3", "Arrival (2016)", 329_865),
            ("m-4", "|||", nil),
            ("m-5", "Heat (1995) SD", nil),
            ("m-6", "Heat (1995) HD", nil)
        ]
        for (index, row) in movies.enumerated() {
            let movie = Movie(id: row.id, streamId: index, name: row.name)
            movie.categoryId = Self.category
            movie.tmdbId = row.tmdbId
            context.insert(movie)
        }
        for (index, name) in ["Dark (2017) HD", "Dark (2017) 4K"].enumerated() {
            let series = Series(id: "s-\(index)", seriesId: index, name: name)
            series.categoryId = Self.category
            context.insert(series)
        }
        try context.save()
    }

    private let defaults = UserDefaults(suiteName: "TitleGroupKeyBackfillTests-\(UUID().uuidString)")!

    private func backfiller(_ container: ModelContainer, batchSize: Int) -> TitleGroupKeyBackfiller {
        TitleGroupKeyBackfiller(
            modelContainer: container, batchSize: batchSize, batchPause: .zero, busyPause: .milliseconds(5), defaults: defaults
        )
    }

    private func movies(_ container: ModelContainer) throws -> [String: Movie] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<Movie>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    @Test func `keys every row and elects one primary per category group across chunks`() async throws {
        try await withContainer { container in
            try insertLegacy(into: container)

            // Chunks of two put a key-less row ("|||") mid-pass and split the
            // Heat group across chunks.
            let filled = try await backfiller(container, batchSize: 2).run { false }

            #expect(filled == TitleGroupKeyBackfiller.Filled(movies: 5, series: 2))
            let movies = try movies(container)
            #expect(movies["m-1"]?.titleGroupKey == "t:inception|2010")
            #expect(movies["m-1"]?.titleGroupKey == movies["m-2"]?.titleGroupKey)
            #expect(movies["m-3"]?.titleGroupKey == "tmdb:329865", "tmdbId takes precedence over the title")
            #expect(movies["m-3"]?.titleMatchKey == "t:arrival|2016")
            #expect(movies["m-4"]?.titleGroupKey == nil, "A title that normalises to nothing is never grouped")
            #expect(movies["m-2"]?.isCategoryGroupPrimary == true)
            #expect(movies["m-1"]?.isCategoryGroupPrimary == false)
            #expect(movies["m-6"]?.isCategoryGroupPrimary == true)
            #expect(movies["m-5"]?.isCategoryGroupPrimary == false)
            #expect(movies["m-3"]?.isCategoryGroupPrimary == true)

            let series = try ModelContext(container).fetch(FetchDescriptor<Series>())
            #expect(series.allSatisfy { $0.titleGroupKey == "t:dark|2017" })
            #expect(series.first { $0.id == "s-1" }?.isCategoryGroupPrimary == true)
            #expect(series.first { $0.id == "s-0" }?.isCategoryGroupPrimary == false)
        }
    }

    @Test func `a second pass finds nothing left to key`() async throws {
        try await withContainer { container in
            try insertLegacy(into: container)
            _ = try await backfiller(container, batchSize: 2000).run { false }

            let again = try await backfiller(container, batchSize: 2000).run { false }

            #expect(again == TitleGroupKeyBackfiller.Filled())
        }
    }

    @Test func `fills the match key of rows that already have a group key`() async throws {
        try await withContainer { container in
            let context = ModelContext(container)
            let movie = Movie(id: "m-1", streamId: 1, name: "Arrival (2016) 4K")
            movie.categoryId = Self.category
            movie.tmdbId = 329_865
            movie.titleGroupKey = "tmdb:329865"
            context.insert(movie)
            let series = Series(id: "s-1", seriesId: 1, name: "Dark (2017) HD")
            series.categoryId = Self.category
            series.titleGroupKey = "t:dark|2017"
            context.insert(series)
            try context.save()

            let filled = try await backfiller(container, batchSize: 2000).run { false }

            #expect(filled == TitleGroupKeyBackfiller.Filled(movies: 1, series: 1))
            let movies = try movies(container)
            #expect(movies["m-1"]?.titleGroupKey == "tmdb:329865")
            #expect(movies["m-1"]?.titleMatchKey == "t:arrival|2016")
            let stored = try ModelContext(container).fetch(FetchDescriptor<Series>())
            #expect(stored.first?.titleMatchKey == "t:dark|2017")
        }
    }

    /// A store keyed before the bridge existed: an Xtream row carrying the
    /// tmdbId, m3u copies on their title key, one of them still key-less.
    @Test func `bridges a store keyed before the bridge`() async throws {
        try await withContainer { container in
            let context = ModelContext(container)
            let carrier = Movie(id: "x-1", streamId: 1, name: "The Matrix (1999)")
            carrier.categoryId = "X-vod-1"
            carrier.tmdbId = 603
            TitleGroupPrimaries.assignKey(to: carrier)
            context.insert(carrier)
            for (index, name) in ["The Matrix (1999) FHD", "The Matrix (1999) 4K", "The Matrix (1999) SD"].enumerated() {
                let copy = Movie(id: "m-\(index)", streamId: 10 + index, name: name)
                copy.categoryId = "M-vod-1"
                if index < 2 { TitleGroupPrimaries.assignKey(to: copy) }
                copy.isCategoryGroupPrimary = true
                context.insert(copy)
            }
            try context.save()

            // Chunks of one page the bridge across several saves.
            let filled = try await backfiller(container, batchSize: 1).run { false }

            #expect(filled == TitleGroupKeyBackfiller.Filled(movies: 1, series: 0))
            let movies = try movies(container)
            #expect(movies["m-2"]?.titleMatchKey == "t:the matrix|1999")
            for id in ["m-0", "m-1", "m-2"] {
                #expect(movies[id]?.titleGroupKey == "tmdb:603")
                #expect(movies[id]?.tmdbId == nil)
            }
            #expect(movies.values.filter { $0.categoryId == "M-vod-1" && $0.isCategoryGroupPrimary }.map(\.id) == ["m-1"])
            #expect(defaults.bool(forKey: TitleGroupKeyBackfiller.bridgedKey))

            let again = try await backfiller(container, batchSize: 1).run { false }
            #expect(again == TitleGroupKeyBackfiller.Filled())
        }
    }

    @Test func `waits while the foreground is busy`() async throws {
        try await withContainer { container in
            try insertLegacy(into: container)
            let calls = BusyCounter()

            let filled = try await backfiller(container, batchSize: 2000).run {
                await calls.next() <= 2
            }

            #expect(filled.movies == 5)
            #expect(await calls.count > 2)
        }
    }
}

private actor BusyCounter {
    private(set) var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

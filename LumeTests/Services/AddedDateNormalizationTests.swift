//
//  AddedDateNormalizationTests.swift
//  LumeTests
//
//  The one-time rewrite of stored "added" stamps, on a real store file: its
//  candidates are read with SQL against that file, and the Recently Added
//  order it exists for is SQLite's binary collation, which an in-memory store
//  never applies.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct AddedDateNormalizationTests {
    /// Stored values as each source wrote them before `CatalogAddedDate`,
    /// keyed by the row id, with the value the rewrite must leave behind.
    private let legacy: [(id: String, stored: String?, expected: String?)] = [
        ("xtream", "1704103300", "1704103300"),
        ("stalker", "2024-01-01 10:00:00", "1704103200"),
        ("jellyfin", "2024-01-02T00:00:00.0000000Z", "1704153600"),
        ("plex", "2023-12-31", "1703980800"),
        ("old", "999999999", "0999999999"),
        ("millis", "1704103200123", "1704103200"),
        ("junk", "yesterday", nil),
        ("m3u", nil, nil)
    ]

    private func withContainer<T>(_ body: (ModelContainer) async throws -> T) async throws -> T {
        let schema = OnDiskCatalogStore.catalogSchema
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(
            schema: schema,
            url: directory.appendingPathComponent("added.store"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        return try await body(container)
    }

    private func insertLegacy(into container: ModelContainer) throws {
        let context = ModelContext(container)
        for (index, row) in legacy.enumerated() {
            context.insert(Movie(id: "movie-\(row.id)", streamId: index, name: row.id, added: row.stored, num: index))
            context.insert(Series(id: "series-\(row.id)", seriesId: index, name: row.id, lastModified: row.stored, num: index))
        }
        try context.save()
    }

    private func normalizer(_ container: ModelContainer, batchSize: Int = 2000) -> AddedDateNormalizer {
        AddedDateNormalizer(modelContainer: container, batchSize: batchSize, batchPause: .zero, busyPause: .milliseconds(5))
    }

    private func storedMovies(_ container: ModelContainer) throws -> [String: String?] {
        let movies = try ModelContext(container).fetch(FetchDescriptor<Movie>())
        return Dictionary(uniqueKeysWithValues: movies.map { ($0.id, $0.added) })
    }

    private func storedSeries(_ container: ModelContainer) throws -> [String: String?] {
        let series = try ModelContext(container).fetch(FetchDescriptor<Series>())
        return Dictionary(uniqueKeysWithValues: series.map { ($0.id, $0.lastModified) })
    }

    // MARK: - Rewrite

    @Test func `rewrites every legacy format and nothing already normalised`() async throws {
        try await withContainer { container in
            try insertLegacy(into: container)

            let rewritten = try await normalizer(container).run { false }

            // Everything but the Xtream stamp and the M3U row (no stamp at all).
            #expect(rewritten == AddedDateNormalizer.Rewritten(movies: 6, series: 6))
            let movies = try storedMovies(container)
            let series = try storedSeries(container)
            for row in legacy {
                #expect(movies["movie-\(row.id)"] == row.expected, "movie \(row.id)")
                #expect(series["series-\(row.id)"] == row.expected, "series \(row.id)")
            }
        }
    }

    @Test func `a second pass finds nothing to do`() async throws {
        try await withContainer { container in
            try insertLegacy(into: container)
            _ = try await normalizer(container).run { false }
            let afterFirst = try storedMovies(container)

            let second = try await normalizer(container).run { false }

            #expect(second == AddedDateNormalizer.Rewritten())
            #expect(try storedMovies(container) == afterFirst)
        }
    }

    @Test func `small batches still reach every row`() async throws {
        try await withContainer { container in
            try insertLegacy(into: container)

            let rewritten = try await normalizer(container, batchSize: 2).run { false }

            #expect(rewritten == AddedDateNormalizer.Rewritten(movies: 6, series: 6))
            #expect(try storedSeries(container)["series-stalker"] == "1704103200")
        }
    }

    @Test func `an empty catalog completes without writing`() async throws {
        try await withContainer { container in
            let rewritten = try await normalizer(container).run { false }
            #expect(rewritten == AddedDateNormalizer.Rewritten())
        }
    }

    @Test func `waits while the app is busy before writing`() async throws {
        try await withContainer { container in
            try insertLegacy(into: container)
            let gate = BusyGate(busyChecks: 3)

            let rewritten = try await normalizer(container).run { await gate.isBusy() }

            #expect(await gate.checks >= 4)
            #expect(rewritten.movies == 6)
        }
    }

    // MARK: - Completion flag

    @Test func `the flag is set once the pass completes`() async throws {
        try await withContainer { container in
            try insertLegacy(into: container)
            let defaults = try #require(UserDefaults(suiteName: "added.normalization.\(UUID().uuidString)"))
            #expect(!defaults.bool(forKey: AddedDateNormalization.completedKey))

            await AddedDateNormalization.run(normalizer(container), defaults: defaults) { false }

            #expect(defaults.bool(forKey: AddedDateNormalization.completedKey))
            #expect(try storedMovies(container)["movie-plex"] == "1703980800")
        }
    }

    // MARK: - Recently Added across sources

    @Test func `recently added orders every source chronologically after the rewrite`() async throws {
        try await withContainer { container in
            try insertLegacy(into: container)
            _ = try await normalizer(container).run { false }
            let context = ModelContext(container)

            let movieOrder = try context.fetch(FetchDescriptor<Movie>(sortBy: ContentSortOption.newest.movieDescriptors)).map(\.name)
            let seriesOrder = try context.fetch(FetchDescriptor<Series>(sortBy: ContentSortOption.newest.seriesDescriptors)).map(\.name)

            // Jellyfin 2024-01-02, Xtream 2024-01-01 10:01:40, Stalker and the
            // millisecond stamp at 10:00:00 (tie broken by `num`), Plex
            // 2023-12-31, the 9-digit 2001 stamp; rows without a stamp last.
            let expected = ["jellyfin", "xtream", "stalker", "millis", "plex", "old"]
            #expect(Array(movieOrder.prefix(expected.count)) == expected)
            #expect(Array(seriesOrder.prefix(expected.count)) == expected)
            #expect(Set(movieOrder.suffix(2)) == ["junk", "m3u"])
            #expect(Set(seriesOrder.suffix(2)) == ["junk", "m3u"])
        }
    }
}

private actor BusyGate {
    private let busyChecks: Int
    private(set) var checks = 0

    init(busyChecks: Int) {
        self.busyChecks = busyChecks
    }

    func isBusy() -> Bool {
        checks += 1
        return checks <= busyChecks
    }
}

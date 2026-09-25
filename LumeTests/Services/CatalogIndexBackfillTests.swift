//
//  CatalogIndexBackfillTests.swift
//  LumeTests
//
//  `CatalogIndexBackfill` writes raw `CREATE INDEX` statements against the
//  catalog store, so its table and column names are hand-written strings that
//  no compiler checks. A typo there is silent — the index simply never appears
//  and the queries stay slow, which is exactly the failure this whole mechanism
//  exists to fix. These tests run it against a real on-disk store built from the
//  live models, so a renamed property or model breaks the build's tests rather
//  than a user's browse.
//

import Foundation
@testable import Lume
import SQLite3
import SwiftData
import Testing

@MainActor
struct CatalogIndexBackfillTests {
    /// The indexes the backfill is responsible for, as `(name, table)`. Kept as
    /// literals rather than read back from the type under test so a mistake in
    /// its table has to be made twice to pass.
    private static let expected: [(name: String, table: String)] = [
        ("Z_Movie_SwiftDataIndexOnBinaryadded", "ZMOVIE"),
        ("Z_Series_SwiftDataIndexOnBinarylastModified", "ZSERIES"),
        ("Z_LiveStream_SwiftDataIndexOnBinaryisFavoriteisHidden", "ZLIVESTREAM"),
        ("Z_LiveStream_SwiftDataIndexOnBinaryisHiddenlastWatchedDate", "ZLIVESTREAM"),
        ("Z_EPGListing_SwiftDataIndexOnBinarychannelIdend", "ZEPGLISTING")
    ]

    /// Builds a real SQLite-backed catalog store and returns its URL. The
    /// container is returned too and must outlive the test — see
    /// `SearchPredicateTests` for why.
    private func makeStore() throws -> (container: ModelContainer, url: URL) {
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
        let container = try ModelContainer(for: schema, configurations: [config])
        // Force the store to actually exist on disk before anything reads it.
        let context = ModelContext(container)
        context.insert(Movie(id: "m1", streamId: 1, name: "A Movie"))
        try context.save()
        return (container, url)
    }

    private func indexNames(in url: URL) -> Set<String> {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = handle
        else {
            if let handle { sqlite3_close(handle) }
            return []
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE type = 'index'", -1, &statement, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { names.insert(String(cString: raw)) }
        }
        return names
    }

    private func drop(_ names: some Sequence<String>, in url: URL) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database = handle
        else {
            if let handle { sqlite3_close(handle) }
            return
        }
        defer { sqlite3_close(database) }
        for name in names {
            sqlite3_exec(database, "DROP INDEX IF EXISTS \(name)", nil, nil, nil)
        }
    }

    /// The case that matters: a store created before the `#Index` entries
    /// existed. SwiftData never revisits `#Index` on an existing file, so
    /// dropping the indexes reproduces exactly what every updating user has.
    @Test func `backfill creates the indexes an older store is missing`() throws {
        let (container, url) = try makeStore()
        _ = container

        drop(Self.expected.map(\.name), in: url)
        let before = indexNames(in: url)
        for expected in Self.expected {
            #expect(!before.contains(expected.name), "\(expected.name) should have been dropped")
        }

        CatalogIndexBackfill.run(storeURL: url)

        let after = indexNames(in: url)
        for expected in Self.expected {
            #expect(after.contains(expected.name), "\(expected.name) was not created — check its table and column names")
        }
    }

    /// A fresh install already has these from the model declarations, so the
    /// backfill must be a no-op rather than creating a second, differently
    /// named copy of each.
    @Test func `backfill is a no-op on a store that already has them`() throws {
        let (container, url) = try makeStore()
        _ = container

        let before = indexNames(in: url)
        CatalogIndexBackfill.run(storeURL: url)
        #expect(indexNames(in: url) == before)
    }

    /// A missing file is the pre-first-launch state; it must not create one.
    @Test func `backfill leaves a missing store alone`() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("absent.store")
        CatalogIndexBackfill.run(storeURL: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

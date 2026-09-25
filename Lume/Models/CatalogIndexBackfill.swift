//
//  CatalogIndexBackfill.swift
//  Lume
//
//  Creates the catalog store's newer `#Index` entries on a store that already
//  exists, because SwiftData will not.
//
//  Measured on a real 373 MB store (2026-09-08, and again after this PR's model
//  changes): adding an entry to `#Index<Movie>` and relaunching leaves
//  `sqlite_master` byte-identical and every `EXPLAIN QUERY PLAN` unchanged.
//  Declaring a `VersionedSchema` pair and opening at the newer version does not
//  help either — the store kept `NSStoreModelVersionIdentifiers = ["1.0.0"]`
//  and no `CREATE INDEX` was issued. The reason is in Core Data's own contract:
//  an entity's version hash covers attributes and relationships and
//  deliberately excludes fetch indexes, so a store whose entities are unchanged
//  is judged compatible, opened as-is, and no migration stage is ever
//  considered. The `#Index` declarations only reach a store at the moment the
//  file is created — i.e. fresh installs.
//
//  So the indexes are created here, directly, once, before the container opens.
//  An index is a pure SQLite object: it changes no row, no column and no
//  version hash, and Core Data neither validates nor notices `sqlite_master`.
//  Each statement is named exactly what SwiftData names its own, so
//  `IF NOT EXISTS` is a no-op on a fresh install that already has them, and a
//  future SwiftData migration finds its index already in place.
//
//  A failure here is not an error worth surfacing: the queries still return the
//  same rows, just more slowly, which is precisely where this app was before.
//

import Foundation
import OSLog
import SQLite3

nonisolated enum CatalogIndexBackfill {
    /// One index this app needs the store to have.
    ///
    /// `name` mirrors SwiftData's own convention — `Z_<Model>_SwiftDataIndexOn`
    /// plus `Binary` (the collation it always uses) plus the property names
    /// concatenated — so it collides with, rather than duplicates, the index a
    /// freshly-created store already carries. See any `Z_LiveStream_…` entry in
    /// an existing store for the shape.
    private struct Index {
        let name: String
        let table: String
        let columns: [String]

        var createStatement: String {
            let cols = columns.map { "\($0) COLLATE BINARY ASC" }.joined(separator: ", ")
            return "CREATE INDEX IF NOT EXISTS \(name) ON \(table) (\(cols))"
        }
    }

    /// The indexes added after the store format was first shipped. Each one is
    /// declared on its `@Model` as well — that is what gives fresh installs the
    /// index — and repeated here because an existing store never sees that
    /// declaration.
    ///
    /// Keep the two in step: a new `#Index` entry that is not listed here
    /// silently helps only new users.
    private static let indexes: [Index] = [
        // "Recently Added" on the Movies and Series tabs sorts on these string
        // columns. Unindexed, the rail cost `SCAN ZMOVIE` plus a temp B-tree
        // sort of all 179,104 rows — 222 ms per run, re-run on every catalog
        // write. Only usable because the sort descriptors pass
        // `comparator: .lexical`; the default localized comparator emits
        // `COLLATE NSCollateFinderlike`, which no binary index can serve.
        Index(name: "Z_Movie_SwiftDataIndexOnBinaryadded", table: "ZMOVIE", columns: ["ZADDED"]),
        Index(name: "Z_Series_SwiftDataIndexOnBinarylastModified", table: "ZSERIES", columns: ["ZLASTMODIFIED"]),
        // The Live TV rail's two section gates and its virtual collections.
        // With only the single-column indexes present SQLite chose the
        // `isHidden` one — which matches ~54,000 of 56,895 channels — and never
        // used `isFavorite` or `lastWatchedDate`: 7.6 ms and 8.0 ms per run,
        // 18-25 runs on a cold launch of a tab that may never be opened.
        // Measured with the composites: 0.6 ms and 0.02 ms.
        Index(
            name: "Z_LiveStream_SwiftDataIndexOnBinaryisFavoriteisHidden",
            table: "ZLIVESTREAM",
            columns: ["ZISFAVORITE", "ZISHIDDEN"]
        ),
        // Equality column first — see the note on `#Index<LiveStream>`: the
        // intuitive `[lastWatchedDate, isHidden]` order is not chosen without
        // table statistics, and Core Data never runs ANALYZE.
        Index(
            name: "Z_LiveStream_SwiftDataIndexOnBinaryisHiddenlastWatchedDate",
            table: "ZLIVESTREAM",
            columns: ["ZISHIDDEN", "ZLASTWATCHEDDATE"]
        ),
        // The in-player EPG lookups bound on `end > now`; the store only had
        // `[channelId, start]`. `TVPlayerContent.guideListings` has cited a
        // "channelId + end index" in a comment since it was written, without
        // one ever existing.
        Index(
            name: "Z_EPGListing_SwiftDataIndexOnBinarychannelIdend",
            table: "ZEPGLISTING",
            columns: ["ZCHANNELID", "ZEND"]
        )
    ]

    /// Creates any missing index on the store at `url`, if that store exists.
    ///
    /// Must run *before* the `ModelContainer` opens the file: this takes its own
    /// connection, and `CREATE INDEX` takes a write lock for as long as it needs
    /// to build the b-tree (a second or two for the largest table on a very big
    /// catalog, once, on the launch after updating — never again).
    ///
    /// Does nothing when the file is absent, which is every fresh install: there
    /// the `#Index` declarations on the models create these at store-creation
    /// time and this finds nothing to do on the next launch either.
    static func run(storeURL: URL) {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }

        var handle: OpaquePointer?
        // No SQLITE_OPEN_CREATE: if the path is wrong we want to do nothing, not
        // leave an empty database next to the real one.
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database = handle
        else {
            if let handle { sqlite3_close(handle) }
            Logger.database.debug("Catalog index backfill: could not open the store; leaving it alone")
            return
        }
        defer { sqlite3_close(database) }

        for index in indexes where tableExists(index.table, in: database) {
            if sqlite3_exec(database, index.createStatement, nil, nil, nil) != SQLITE_OK {
                let message = String(cString: sqlite3_errmsg(database))
                Logger.database.debug("Catalog index backfill: \(index.name, privacy: .public) skipped — \(message, privacy: .public)")
            }
        }
    }

    /// Guards against running `CREATE INDEX` on a store from before a model
    /// existed — a missing table is a skip, not an error.
    private static func tableExists(_ table: String, in database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }
}

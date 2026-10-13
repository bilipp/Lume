//
//  AddedDateNormalization.swift
//  Lume
//
//  Rewrites the `Movie.added` and `Series.lastModified` values stored before
//  every importer wrote `CatalogAddedDate`'s ten-digit form, once per device.
//  Until then a Stalker, Jellyfin/Emby or Plex date string outranks every Unix
//  value under the `.lexical` "Recently Added" sort. Local only: the provider
//  is never asked, and the next sync of those rows compares normalised values
//  on both sides, so the rewrite invalidates no digest and re-fetches nothing.
//

import Foundation
import OSLog
import SQLite3
import SwiftData

enum AddedDateNormalization {
    static let completedKey = "lume.catalogAddedDateNormalized.v1"

    private static var task: Task<Void, Never>?

    /// Starts the pass unless this device finished it already. It stands aside
    /// while anything playback, iCloud or browsing would feel is happening: each
    /// batch save forces a main-context merge that re-runs every `@Query`.
    static func runIfNeeded(container: ModelContainer, defaults: UserDefaults = .standard) {
        guard task == nil, !defaults.bool(forKey: completedKey) else { return }
        let normalizer = AddedDateNormalizer(modelContainer: container)
        let gate = ContentIndexingService.shared
        task = Task(priority: .utility) {
            defer { task = nil }
            await run(normalizer, defaults: defaults) { @MainActor in
                gate.isForegroundBusy
            }
        }
    }

    /// Sets the flag only when the pass reached the end; an interrupted or
    /// failed pass starts over on the next launch, which the rewrite tolerates.
    static func run(
        _ normalizer: AddedDateNormalizer,
        defaults: UserDefaults,
        isBusy: @escaping @Sendable () async -> Bool
    ) async {
        do {
            let rewritten = try await normalizer.run(isBusy: isBusy)
            defaults.set(true, forKey: completedKey)
            Logger.sync.info("Normalised added dates: \(rewritten.movies) movies, \(rewritten.series) series")
        } catch is CancellationError {
            return
        } catch {
            Logger.sync.error("Added-date normalisation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

actor AddedDateNormalizer {
    nonisolated struct Rewritten: Equatable {
        var movies = 0
        var series = 0
    }

    nonisolated enum Failure: Error {
        case storeUnreadable(String)
    }

    private let modelContainer: ModelContainer
    private let batchSize: Int
    private let batchPause: Duration
    private let busyPause: Duration

    init(
        modelContainer: ModelContainer,
        batchSize: Int = 1000,
        batchPause: Duration = .milliseconds(500),
        busyPause: Duration = .seconds(20)
    ) {
        self.modelContainer = modelContainer
        self.batchSize = batchSize
        self.batchPause = batchPause
        self.busyPause = busyPause
    }

    /// Throws when the catalog can't be read, so a store that is mid-detach is
    /// retried on a later launch instead of being marked done.
    func run(isBusy: @Sendable () async -> Bool) async throws -> Rewritten {
        guard let configuration = modelContainer.configurations.first,
              !configuration.isStoredInMemoryOnly
        else { return Rewritten() }
        let probe = ModelContext(modelContainer)
        guard try probe.fetchCount(FetchDescriptor<Movie>()) + probe.fetchCount(FetchDescriptor<Series>()) > 0 else {
            return Rewritten()
        }

        let storeURL = configuration.url
        var rewritten = Rewritten()
        rewritten.movies = try await pass(storeURL: storeURL, table: "ZMOVIE", column: "ZADDED", isBusy: isBusy) { ids in
            try rewrite(FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) }), \.added)
        }
        rewritten.series = try await pass(storeURL: storeURL, table: "ZSERIES", column: "ZLASTMODIFIED", isBusy: isBusy) { ids in
            try rewrite(FetchDescriptor<Series>(predicate: #Predicate { ids.contains($0.id) }), \.lastModified)
        }
        return rewritten
    }

    private func pass(
        storeURL: URL,
        table: String,
        column: String,
        isBusy: @Sendable () async -> Bool,
        rewrite: ([String]) throws -> Int
    ) async throws -> Int {
        let reader = try CandidateReader(storeURL: storeURL, table: table, column: column, batchSize: batchSize)
        var cursor: Int64 = 0
        var changed = 0
        while true {
            try await waitWhileBusy(isBusy)
            let batch = try reader.batch(after: cursor)
            guard let last = batch.lastPK else { return changed }
            cursor = last
            changed += try rewrite(batch.ids)
            try await Task.sleep(for: batchPause)
        }
    }

    private func waitWhileBusy(_ isBusy: @Sendable () async -> Bool) async throws {
        while true {
            try Task.checkCancellation()
            if try !Playlist.isAnySyncing(in: modelContainer), await !isBusy() { return }
            try await Task.sleep(for: busyPause)
        }
    }

    // MARK: - Rewrite

    /// An unreadable stamp becomes nil, which is what a sync stores for one.
    private func rewrite<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        _ field: ReferenceWritableKeyPath<T, String?>
    ) throws -> Int {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var changed = 0
        for model in try context.fetch(descriptor) {
            let normalised = CatalogAddedDate.unixString(model[keyPath: field])
            guard normalised != model[keyPath: field] else { continue }
            model[keyPath: field] = normalised
            changed += 1
        }
        if changed > 0 { try context.save() }
        return changed
    }
}

/// The ids of the next rows whose stamp isn't ten digits, read on a read-only
/// connection of its own that lives for one pass. Not a `#Predicate`:
/// SwiftData renders `String.count` as something that is never 10 — on a real
/// store `count == 10` matched no row and `count != 10` matched every one — and
/// has no digit test, so a 9-digit or millisecond Xtream stamp would be
/// unreachable without realising the whole catalog.
private final nonisolated class CandidateReader {
    private let database: OpaquePointer
    private let statement: OpaquePointer
    private let batchSize: Int64

    init(storeURL: URL, table: String, column: String, batchSize: Int) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = handle
        else {
            if let handle { sqlite3_close(handle) }
            throw AddedDateNormalizer.Failure.storeUnreadable("open")
        }
        let sql = """
        SELECT Z_PK, ZID FROM \(table)
        WHERE Z_PK > ? AND \(column) IS NOT NULL
          AND (length(\(column)) != \(CatalogAddedDate.width) OR \(column) GLOB '*[^0-9]*')
        ORDER BY Z_PK LIMIT ?
        """
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            let message = String(cString: sqlite3_errmsg(database))
            sqlite3_finalize(prepared)
            sqlite3_close(database)
            throw AddedDateNormalizer.Failure.storeUnreadable(message)
        }
        self.database = database
        self.statement = statement
        self.batchSize = Int64(batchSize)
    }

    deinit {
        sqlite3_finalize(statement)
        sqlite3_close(database)
    }

    func batch(after cursor: Int64) throws -> (ids: [String], lastPK: Int64?) {
        defer { sqlite3_reset(statement) }
        sqlite3_bind_int64(statement, 1, cursor)
        sqlite3_bind_int64(statement, 2, batchSize)

        var ids: [String] = []
        var lastPK: Int64?
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw AddedDateNormalizer.Failure.storeUnreadable(String(cString: sqlite3_errmsg(database)))
            }
            lastPK = sqlite3_column_int64(statement, 0)
            if let text = sqlite3_column_text(statement, 1) {
                ids.append(String(cString: text))
            }
        }
        return (ids, lastPK)
    }
}

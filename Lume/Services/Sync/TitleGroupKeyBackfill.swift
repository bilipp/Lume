//
//  TitleGroupKeyBackfill.swift
//  Lume
//
//  Fills `titleGroupKey`, `titleMatchKey` and the per-category primaries for
//  movie and series rows stored before the columns existed. Imports key every
//  row they write, so after the first full pass this only finds rows whose
//  title normalises to nothing, which stay ungrouped. Once per store it then
//  bridges every tmdbId-less row onto the `tmdb:` group of its title.
//

import Foundation
import OSLog
import SwiftData

enum TitleGroupKeyBackfill {
    private static var task: Task<Void, Never>?

    /// Starts the pass once per launch. It stands aside while a playlist sync,
    /// playback, iCloud or browsing is active: each chunk save forces a
    /// main-context merge that re-runs every `@Query`.
    static func run(container: ModelContainer) {
        guard task == nil else { return }
        let backfiller = TitleGroupKeyBackfiller(modelContainer: container)
        let gate = ContentIndexingService.shared
        task = Task(priority: .utility) {
            defer { task = nil }
            do {
                let filled = try await backfiller.run { @MainActor in
                    gate.isForegroundBusy
                }
                if filled.movies + filled.series > 0 {
                    Logger.sync.info("Title group keys backfilled: \(filled.movies) movies, \(filled.series) series")
                }
            } catch is CancellationError {
                return
            } catch {
                Logger.sync.error("Title group key backfill failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

actor TitleGroupKeyBackfiller {
    nonisolated struct Filled: Equatable {
        var movies = 0
        var series = 0
    }

    /// One chunk: how many rows missing a key it read and how many it keyed.
    nonisolated struct Chunk: Equatable {
        let fetched: Int
        let keyed: Int
    }

    private let modelContainer: ModelContainer
    private let batchSize: Int
    private let batchPause: Duration
    private let busyPause: Duration
    private let defaults: UserDefaults

    /// Set once every stored row went through the bridge; imports and prunes
    /// bridge what they touch from then on.
    static let bridgedKey = "sync.titleGroupKeysBridged"

    init(
        modelContainer: ModelContainer,
        batchSize: Int = 2000,
        batchPause: Duration = .milliseconds(500),
        busyPause: Duration = .seconds(20),
        defaults: UserDefaults = .standard
    ) {
        self.modelContainer = modelContainer
        self.batchSize = batchSize
        self.batchPause = batchPause
        self.busyPause = busyPause
        self.defaults = defaults
    }

    func run(isBusy: @Sendable () async -> Bool) async throws -> Filled {
        var filled = Filled()
        filled.movies = try await pass(isBusy: isBusy) { offset, limit in
            try Self.fillMovies(in: Self.context(modelContainer), offset: offset, limit: limit)
        }
        filled.series = try await pass(isBusy: isBusy) { offset, limit in
            try Self.fillSeries(in: Self.context(modelContainer), offset: offset, limit: limit)
        }
        if !defaults.bool(forKey: Self.bridgedKey) {
            try await bridgePass(isBusy: isBusy) { cursor, limit in
                try Self.bridgeMovies(in: Self.context(modelContainer), after: cursor, limit: limit)
            }
            try await bridgePass(isBusy: isBusy) { cursor, limit in
                try Self.bridgeSeries(in: Self.context(modelContainer), after: cursor, limit: limit)
            }
            defaults.set(true, forKey: Self.bridgedKey)
        }
        return filled
    }

    /// Pages through the rows the bridge could re-key by id; `chunk` returns
    /// the last id it read, or nil once the rows ran out.
    private func bridgePass(
        isBusy: @Sendable () async -> Bool,
        chunk: (_ cursor: String, _ limit: Int) throws -> String?
    ) async throws {
        var cursor = ""
        while true {
            try await waitWhileBusy(isBusy)
            guard let last = try chunk(cursor, batchSize) else { return }
            cursor = last
            try await Task.sleep(for: batchPause)
        }
    }

    /// Rows that stay key-less sort before every row not yet read, so skipping
    /// as many as earlier chunks left behind reaches the next unread row.
    private func pass(
        isBusy: @Sendable () async -> Bool,
        chunk: (_ offset: Int, _ limit: Int) throws -> Chunk
    ) async throws -> Int {
        var leftKeyless = 0
        var keyed = 0
        while true {
            try await waitWhileBusy(isBusy)
            let result = try chunk(leftKeyless, batchSize)
            keyed += result.keyed
            leftKeyless += result.fetched - result.keyed
            guard result.fetched == batchSize else { return keyed }
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

    private nonisolated static func context(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }
}

// MARK: - Chunks

nonisolated extension TitleGroupKeyBackfiller {
    /// Keys up to `limit` movies missing either key after the first `offset`,
    /// re-elects the primaries of the groups they joined and saves once.
    static func fillMovies(in context: ModelContext, offset: Int, limit: Int) throws -> Chunk {
        let descriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.titleGroupKey == nil || $0.titleMatchKey == nil },
            sortBy: [SortDescriptor(\.id, comparator: .lexical)]
        )
        return try fill(descriptor, as: \.movies, in: context, offset: offset, limit: limit)
    }

    static func fillSeries(in context: ModelContext, offset: Int, limit: Int) throws -> Chunk {
        let descriptor = FetchDescriptor<Series>(
            predicate: #Predicate { $0.titleGroupKey == nil || $0.titleMatchKey == nil },
            sortBy: [SortDescriptor(\.id, comparator: .lexical)]
        )
        return try fill(descriptor, as: \.series, in: context, offset: offset, limit: limit)
    }

    /// Bridges the titles of up to `limit` tmdbId-less movies after `cursor`,
    /// re-elects the groups rows left and joined and saves once. Returns the
    /// last id read, nil when the page came back short.
    static func bridgeMovies(in context: ModelContext, after cursor: String, limit: Int) throws -> String? {
        var descriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.tmdbId == nil && $0.titleMatchKey != nil && $0.id > cursor },
            sortBy: [SortDescriptor(\.id, comparator: .lexical)]
        )
        descriptor.propertiesToFetch = [\.id, \.titleMatchKey]
        return try bridge(descriptor, using: .movies, as: \.movies, in: context, limit: limit)
    }

    static func bridgeSeries(in context: ModelContext, after cursor: String, limit: Int) throws -> String? {
        var descriptor = FetchDescriptor<Series>(
            predicate: #Predicate { $0.tmdbId == nil && $0.titleMatchKey != nil && $0.id > cursor },
            sortBy: [SortDescriptor(\.id, comparator: .lexical)]
        )
        descriptor.propertiesToFetch = [\.id, \.titleMatchKey]
        return try bridge(descriptor, using: .series, as: \.series, in: context, limit: limit)
    }

    private static func fill(
        _ descriptor: FetchDescriptor<some PersistentModel & TitleGroupedRow>,
        as kind: WritableKeyPath<TitleGroupPrimaries.Touched, Set<TitleGroupPrimaries.CategoryKey>>,
        in context: ModelContext,
        offset: Int,
        limit: Int
    ) throws -> Chunk {
        var descriptor = descriptor
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        let rows = try context.fetch(descriptor)
        var touched = TitleGroupPrimaries.Touched()
        for row in rows {
            TitleGroupPrimaries.track(row, into: &touched[keyPath: kind]) { TitleGroupPrimaries.assignKey(to: row) }
        }
        return try finish(rows, touched: touched, in: context)
    }

    private static func bridge<Row: PersistentModel & TitleGroupedRow>(
        _ descriptor: FetchDescriptor<Row>,
        using queries: TitleGroupPrimaries.BridgeQueries<Row>,
        as kind: WritableKeyPath<TitleGroupPrimaries.Touched, Set<TitleGroupPrimaries.CategoryKey>>,
        in context: ModelContext,
        limit: Int
    ) throws -> String? {
        var descriptor = descriptor
        descriptor.fetchLimit = limit
        let rows = try context.fetch(descriptor)
        var touched = TitleGroupPrimaries.Touched()
        touched[keyPath: kind] = TitleGroupPrimaries.bridge(matchKeys: Set(rows.compactMap(\.titleMatchKey)), using: queries, in: context)
        return try finishBridge(lastId: rows.last?.id, full: rows.count == limit, touched: touched, in: context)
    }

    private static func finishBridge(
        lastId: String?,
        full: Bool,
        touched: TitleGroupPrimaries.Touched,
        in context: ModelContext
    ) throws -> String? {
        if !touched.isEmpty {
            TitleGroupPrimaries.reelect(categoryKeys: touched, in: context)
        }
        if context.hasChanges { try context.save() }
        return full ? lastId : nil
    }

    private static func finish(_ rows: [some TitleGroupedRow], touched: TitleGroupPrimaries.Touched, in context: ModelContext) throws -> Chunk {
        if !touched.isEmpty {
            TitleGroupPrimaries.recompute(categoryKeys: touched, in: context)
        }
        if context.hasChanges { try context.save() }
        let keyed = rows.count(where: { $0.titleGroupKey != nil && $0.titleMatchKey != nil })
        return Chunk(fetched: rows.count, keyed: keyed)
    }
}

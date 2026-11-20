//
//  TitleGroupPrimaries+Bridge.swift
//  Lume
//
//  Joins a row without a tmdbId to the `tmdb:` group of its title. Providers
//  differ in what they send: an Xtream row carries the provider's tmdb id and
//  is keyed `tmdb:<id>`, an m3u copy of the same title has none and is keyed
//  `t:<title>|<year>`. A tmdbId-less row whose `titleMatchKey` is carried by
//  exactly one tmdbId adopts that id's key; zero or several ids leave it on its
//  match key. Adoption only moves the group key, never the tmdbId.
//

import Foundation
import SwiftData

nonisolated extension TitleGroupPrimaries {
    /// Keys per `IN` list: far below SQLite's 32,766 bound variables.
    static let bridgeChunkSize = 500

    /// The fetches the bridge runs, per kind.
    struct BridgeQueries<Row: PersistentModel & TitleGroupedRow> {
        /// Rows the bridge could re-key: no tmdbId, a match key.
        let titleKeyed: FetchDescriptor<Row>
        /// Rows with a tmdbId and a match key: what a row could adopt.
        let anyCarrier: FetchDescriptor<Row>
        /// tmdbId-less rows in an adopted group: what could revert.
        let anyAdopted: FetchDescriptor<Row>
        /// Rows in the groups `keys`.
        let inGroups: (_ keys: [String?]) -> FetchDescriptor<Row>
        /// Rows whose match key is in `keys`, carriers and tmdbId-less rows
        /// alike: a `tmdbId` term lets SQLite walk the tmdbId index over every
        /// tmdbId-less row instead of the match-key index.
        let matching: (_ keys: [String?]) -> FetchDescriptor<Row>
    }

    /// Bridges the titles behind `groupKeys`: the match keys of the rows in
    /// those groups. Returns the (category, key) pairs re-keyed rows left and
    /// joined, without saving.
    static func bridge(groupKeys: Set<String>, using queries: BridgeQueries<some Any>, in context: ModelContext) -> Set<CategoryKey> {
        guard !groupKeys.isEmpty, hasBridgeWork(queries, in: context) else { return [] }
        return Perf.measure(.titleGroupBridge) {
            bridge(matchKeys: matchKeys(forGroupKeys: groupKeys, using: queries, in: context), using: queries, in: context)
        }
    }

    /// Whether any row could be re-keyed at all: a tmdbId-less row, and
    /// either a carrier to adopt or an adopted row to revert. A cold import of
    /// an m3u-only catalog has neither and skips the per-key queries.
    static func hasBridgeWork(_ queries: BridgeQueries<some Any>, in context: ModelContext) -> Bool {
        // The context subtracts its pending deletes from what the store
        // counted, so a limit of 1 alone can count a deleted row and report 0.
        let pendingDeletes = context.deletedModelsArray.count
        func exists(_ descriptor: FetchDescriptor<some PersistentModel>) -> Bool {
            var descriptor = descriptor
            descriptor.fetchLimit = 1 + pendingDeletes
            return ((try? context.fetchCount(descriptor)) ?? 0) > 0
        }
        return exists(queries.titleKeyed) && (exists(queries.anyCarrier) || exists(queries.anyAdopted))
    }

    /// A `t:` group key is its own match key; a `tmdb:` group holds the match
    /// keys of its rows.
    static func matchKeys(forGroupKeys groupKeys: Set<String>, using queries: BridgeQueries<some Any>, in context: ModelContext) -> Set<String> {
        let split = splitGroupKeys(groupKeys)
        var result = split.matchKeys
        for chunk in split.tmdbChunks {
            result.formUnion(matchKeys(inTMDBGroups: chunk, using: queries, in: context))
        }
        return result
    }

    /// `matchKeys(forGroupKeys:)` on a fresh context per chunk, so the rows
    /// one chunk fetched are released before the next.
    static func matchKeys(forGroupKeys groupKeys: Set<String>, using queries: BridgeQueries<some Any>, in container: ModelContainer) -> Set<String> {
        let split = splitGroupKeys(groupKeys)
        var result = split.matchKeys
        for chunk in split.tmdbChunks {
            autoreleasepool {
                result.formUnion(matchKeys(inTMDBGroups: chunk, using: queries, in: ModelContext(container)))
            }
        }
        return result
    }

    /// The `t:` keys, which are their own match keys, and the `tmdb:` keys in
    /// chunks of `bridgeChunkSize`.
    private static func splitGroupKeys(_ groupKeys: Set<String>) -> (matchKeys: Set<String>, tmdbChunks: [[String?]]) {
        var matchKeys = Set<String>()
        var tmdbKeys: [String?] = []
        for key in groupKeys {
            if key.hasPrefix(TitleGroupKey.tmdbPrefix) { tmdbKeys.append(key) } else { matchKeys.insert(key) }
        }
        let chunks = stride(from: 0, to: tmdbKeys.count, by: bridgeChunkSize).map {
            Array(tmdbKeys[$0 ..< min($0 + bridgeChunkSize, tmdbKeys.count)])
        }
        return (matchKeys, chunks)
    }

    private static func matchKeys(inTMDBGroups keys: [String?], using queries: BridgeQueries<some Any>, in context: ModelContext) -> Set<String> {
        Set(((try? context.fetch(queries.inGroups(keys))) ?? []).compactMap(\.titleMatchKey))
    }

    /// Re-keys the tmdbId-less rows of `matchKeys`, across every playlist.
    static func bridge(matchKeys: Set<String>, using queries: BridgeQueries<some Any>, in context: ModelContext) -> Set<CategoryKey> {
        // Every chunk is fetched before any row changes: a fetch also matches
        // the context's pending changes in memory, so fetching after the
        // first re-keys would scan each earlier chunk's rows again.
        let keys = matchKeys.sorted()
        let rows = stride(from: 0, to: keys.count, by: bridgeChunkSize).flatMap { start in
            let chunk = keys[start ..< min(start + bridgeChunkSize, keys.count)].map { Optional($0) }
            return ((try? context.fetch(queries.matching(chunk))) ?? []).filter { !$0.isDeleted }
        }
        let targets = bridgeTargets(carriers: rows)
        var moved = Set<CategoryKey>()
        for row in rows where row.tmdbId == nil {
            guard let matchKey = row.titleMatchKey else { continue }
            let target = targets[matchKey] ?? matchKey
            // Without a target only an adopted row moves, back to its own key.
            guard row.titleGroupKey != target, targets[matchKey] != nil || row.titleGroupKey != nil else { continue }
            if let key = RowState(row).categoryKey { moved.insert(key) }
            // The indexer stamps an adopter done without searching; a
            // row back on its own key has never been searched.
            if target == matchKey, row.titleGroupKey?.hasPrefix(TitleGroupKey.tmdbPrefix) == true {
                row.indexedAt = nil
            }
            row.titleGroupKey = target
            if let key = RowState(row).categoryKey { moved.insert(key) }
        }
        return moved
    }

    /// The `tmdb:` key of each match key whose carriers among `rows` hold
    /// exactly one tmdbId.
    static func bridgeTargets(carriers rows: [some TitleGroupedRow]) -> [String: String] {
        var ids: [String: Set<Int>] = [:]
        for row in rows {
            guard let matchKey = row.titleMatchKey, let tmdbId = row.tmdbId else { continue }
            ids[matchKey, default: []].insert(tmdbId)
        }
        var targets: [String: String] = [:]
        for (matchKey, carried) in ids where carried.count == 1 {
            targets[matchKey] = TitleGroupKey.key(tmdbId: carried.first, matchKey: matchKey)
        }
        return targets
    }
}

nonisolated extension TitleGroupedRow {
    /// The TMDB id of the row's title: its own, else the one its group
    /// adopted. Enrichment reads it, so an adopting row shows the title's
    /// TMDB data without searching for an id of its own.
    var titleTMDBId: Int? {
        tmdbId ?? TitleGroupKey.tmdbId(groupKey: titleGroupKey)
    }
}

nonisolated extension TitleGroupPrimaries.BridgeQueries where Row == Movie {
    static var movies: Self {
        Self(
            titleKeyed: FetchDescriptor(predicate: #Predicate { $0.tmdbId == nil && $0.titleMatchKey != nil }),
            anyCarrier: FetchDescriptor(predicate: #Predicate { $0.tmdbId != nil && $0.titleMatchKey != nil }),
            anyAdopted: FetchDescriptor(predicate: #Predicate {
                $0.tmdbId == nil && $0.titleMatchKey != nil && $0.titleGroupKey != $0.titleMatchKey
            }),
            inGroups: { keys in
                var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { keys.contains($0.titleGroupKey) })
                descriptor.relationshipKeyPathsForPrefetching = [\.castMembers]
                return descriptor
            },
            matching: { keys in
                var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { keys.contains($0.titleMatchKey) })
                descriptor.relationshipKeyPathsForPrefetching = [\.castMembers]
                return descriptor
            }
        )
    }
}

nonisolated extension TitleGroupPrimaries.BridgeQueries where Row == Series {
    static var series: Self {
        Self(
            titleKeyed: FetchDescriptor(predicate: #Predicate { $0.tmdbId == nil && $0.titleMatchKey != nil }),
            anyCarrier: FetchDescriptor(predicate: #Predicate { $0.tmdbId != nil && $0.titleMatchKey != nil }),
            anyAdopted: FetchDescriptor(predicate: #Predicate {
                $0.tmdbId == nil && $0.titleMatchKey != nil && $0.titleGroupKey != $0.titleMatchKey
            }),
            inGroups: { keys in
                var descriptor = FetchDescriptor<Series>(predicate: #Predicate { keys.contains($0.titleGroupKey) })
                descriptor.relationshipKeyPathsForPrefetching = [\.castMembers]
                return descriptor
            },
            matching: { keys in
                var descriptor = FetchDescriptor<Series>(predicate: #Predicate { keys.contains($0.titleMatchKey) })
                descriptor.relationshipKeyPathsForPrefetching = [\.castMembers]
                return descriptor
            }
        )
    }
}

// MARK: - Bulk bridge

nonisolated extension TitleGroupPrimaries {
    /// Match keys bridged per context before it is saved and dropped.
    static let bridgeKeysPerSave = 5000

    /// `bridge(groupKeys:)` for a bulk change, on contexts of its own, saving
    /// as it goes. Returns the pairs re-keyed rows left and joined.
    static func bridge(groupKeys: Set<String>, using queries: BridgeQueries<some Any>, in container: ModelContainer) throws -> Set<CategoryKey> {
        guard !groupKeys.isEmpty, hasBridgeWork(queries, in: ModelContext(container)) else { return [] }
        let interval = Perf.begin(.titleGroupBridge)
        defer { Perf.end(interval) }
        let matchKeys = Self.matchKeys(forGroupKeys: groupKeys, using: queries, in: container).sorted()
        var moved = Set<CategoryKey>()
        for start in stride(from: 0, to: matchKeys.count, by: bridgeKeysPerSave) {
            try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let chunk = Set(matchKeys[start ..< min(start + bridgeKeysPerSave, matchKeys.count)])
                moved.formUnion(bridge(matchKeys: chunk, using: queries, in: context))
                if context.hasChanges { try context.save() }
            }
        }
        return moved
    }

    /// Bridges, then re-elects, after rows left the catalog in bulk (a
    /// playlist deletion): rows that had adopted a removed row's tmdb key fall
    /// back to their own key, and rows a removed id kept apart adopt the one
    /// left. `movieGroupKeys`/`seriesGroupKeys` are the group and match keys
    /// of the removed rows that carried a tmdbId.
    static func settleRemoval(
        movieGroupKeys: Set<String>,
        seriesGroupKeys: Set<String>,
        in container: ModelContainer,
        preferredLanguages: [String] = PlayerLanguageOptions.load().preferredAudioLanguages
    ) throws {
        var movies = Deferred.Scopes()
        try movies.add(bridge(groupKeys: movieGroupKeys, using: .movies, in: container))
        var series = Deferred.Scopes()
        try series.add(bridge(groupKeys: seriesGroupKeys, using: .series, in: container))
        try Deferred.elect(movies: movies, series: series, in: container, preferredLanguages: preferredLanguages)
    }
}

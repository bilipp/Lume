//
//  ContentSyncManager+StalkerBrowse.swift
//  Lume
//
//  On-demand Stalker browsing: a default sync pulls only the category lists
//  and live channels, so VOD/series content is fetched from the portal when a
//  category is opened (`importStalkerCategory`) and searched through the
//  portal's own API (`searchStalker`) rather than a local index. Both reuse the
//  upsert helpers in `ContentSyncManager+Stalker.swift`.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    // MARK: - On-demand category import

    /// One Stalker VOD/series category's full content, fetched from the portal
    /// and upserted, with the category marked imported so opening it again
    /// reads local rows. The default sync fetches no VOD/series content, so a
    /// category is empty until the user opens it. Returns the number of items
    /// imported. Marks the category imported only when the walk reached its
    /// end, so a truncated fetch retries on the next open.
    @discardableResult
    func importStalkerCategory(apiId: String, type: CategoryType, playlist: Playlist) async throws -> Int {
        guard type == .vod || type == .series, !apiId.isEmpty else { return 0 }
        let client = StalkerClient(configuration: StalkerClient.Configuration(playlist: playlist))
        let playlistId = playlist.id
        let walk = try await client.getAllOrderedItems(
            type: type == .vod ? "vod" : "series", categoryId: apiId
        )
        let playlistPrefix = "\(playlistId.uuidString)-\(type.rawValue)-"
        let entries = walk.items.map { (item: $0, categoryId: apiId) }

        var seen = Set<String>()
        var imported = 0
        let batchSize = 2000
        for start in stride(from: 0, to: entries.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(entries[start ..< min(start + batchSize, entries.count)])
            autoreleasepool {
                switch type {
                case .vod:
                    imported += upsertStalkerMovies(
                        batch, playlistPrefix: playlistPrefix, playlistId: playlistId, seenIds: &seen
                    )
                case .series:
                    imported += upsertStalkerSeries(
                        batch, playlistPrefix: playlistPrefix, playlistId: playlistId, seenIds: &seen
                    )
                case .live:
                    break
                }
            }
        }
        if walk.complete {
            markStalkerCategoryImported(apiId: apiId, type: type, playlistId: playlistId)
        }
        Logger.database.info("Stalker: imported \(imported) items for category \(apiId)")
        return imported
    }

    /// Stamps one category's `contentImportedAt`.
    private func markStalkerCategoryImported(apiId: String, type: CategoryType, playlistId: UUID) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let categoryId = "\(playlistId.uuidString)-\(type.rawValue)-\(apiId)"
        guard let category = try? context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.id == categoryId })
        ).first else { return }
        category.contentImportedAt = Date()
        try? context.save()
    }

    /// Stamps every category of `type` imported — used after a completed full
    /// catalog download, which already pulled all of them.
    func markAllStalkerCategoriesImported(type: CategoryType, playlistId: UUID) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let typeRaw = type.rawValue
        let prefix = playlistId.uuidString
        let cats = (try? context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.typeRaw == typeRaw })
        )) ?? []
        let now = Date()
        for category in cats where category.id.hasPrefix(prefix) {
            category.contentImportedAt = now
        }
        try? context.save()
    }

    // MARK: - Search

    /// Searches the portal for `query` and upserts the hits so they surface as
    /// ordinary `Movie` / `Series` rows. Returns the upserted element ids in
    /// the portal's relevance order. Stalker VOD/series aren't synced locally,
    /// so this dedicated search API is the only way to find them — the portal
    /// middleware matches `query` against name, original name, actors,
    /// director and year across the whole catalog. Best-effort: a failed
    /// request just yields no ids for that kind.
    func searchStalker(
        query: String,
        playlist: Playlist,
        includeMovies: Bool,
        includeSeries: Bool,
        limit: Int = 60
    ) async -> (movies: [String], series: [String]) {
        guard playlist.sourceType == .stalker, !query.isEmpty else { return ([], []) }
        let client = StalkerClient(configuration: StalkerClient.Configuration(playlist: playlist))
        let playlistId = playlist.id
        var movieIds: [String] = []
        var seriesIds: [String] = []
        if includeMovies {
            let items = await (try? client.getAllOrderedItems(
                type: "vod", categoryId: "*", search: query, maxItems: limit
            ))?.items ?? []
            movieIds = upsertStalkerSearchHits(items, kind: .vod, playlistId: playlistId)
        }
        if includeSeries {
            let items = await (try? client.getAllOrderedItems(
                type: "series", categoryId: "*", search: query, maxItems: limit
            ))?.items ?? []
            seriesIds = upsertStalkerSearchHits(items, kind: .series, playlistId: playlistId)
        }
        return (movieIds, seriesIds)
    }

    /// Upserts search-hit items and returns their element ids, preserving the
    /// portal's order and dropping duplicates.
    private func upsertStalkerSearchHits(
        _ items: [StalkerVODItem],
        kind: CategoryType,
        playlistId: UUID
    ) -> [String] {
        guard !items.isEmpty else { return [] }
        let playlistPrefix = "\(playlistId.uuidString)-\(kind.rawValue)-"
        let entries = items.map { (item: $0, categoryId: $0.categoryId ?? "*") }
        var seen = Set<String>()
        switch kind {
        case .vod:
            _ = upsertStalkerMovies(entries, playlistPrefix: playlistPrefix, playlistId: playlistId, seenIds: &seen)
        case .series:
            _ = upsertStalkerSeries(entries, playlistPrefix: playlistPrefix, playlistId: playlistId, seenIds: &seen)
        case .live:
            return []
        }
        // Recompute the element ids in portal order. Movies without a `cmd`
        // aren't upserted (see `upsertStalkerMovies`), so skip them here too.
        let elementKind = kind == .vod ? "movie" : "series"
        var ordered: [String] = []
        var unique = Set<String>()
        for item in items {
            guard let stalkerId = item.id else { continue }
            if kind == .vod, item.cmd == nil { continue }
            let id = "\(playlistId.uuidString)-\(elementKind)-\(Self.streamId(for: stalkerId))"
            if unique.insert(id).inserted { ordered.append(id) }
        }
        return ordered
    }
}

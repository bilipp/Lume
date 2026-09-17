//
//  CloudSyncEngine+Fetch.swift
//  Lume
//
//  The reconcile engine's store fetches and defensive de-duplication helpers,
//  split out of CloudSyncEngine.swift to keep that file within the project's
//  line-count cap. Catalog reads route to `catalogContext`, cloud-mirror reads
//  to `cloudContext`.
//

import Foundation
import SwiftData

// MARK: - Fetch maps

/// Not `private`: profile operations in `CloudSyncEngine+Profiles.swift`
/// reuse these helpers (fetch / reset / apply / value extraction).
extension CloudSyncEngine {
    func fetchLocalPlaylists() throws -> [UUID: Playlist] {
        var map: [UUID: Playlist] = [:]
        for playlist in try catalogContext.fetch(FetchDescriptor<Playlist>()) {
            map[playlist.id] = playlist
        }
        return map
    }

    func fetchPlaylistMirrors() throws -> [UUID: SyncedPlaylist] {
        var map: [UUID: SyncedPlaylist] = [:]
        for mirror in try cloudContext.fetch(FetchDescriptor<SyncedPlaylist>()) {
            map[mirror.id] = dedupe(mirror, against: map[mirror.id])
        }
        return map
    }

    /// Manual EPG sources (no owning playlist) keyed by id. Playlist-linked
    /// sources are derived locally and never synced, so they're excluded here.
    /// Filtered in memory — an optional-`UUID?` `#Predicate` is brittle.
    func fetchLocalManualEPGSources() throws -> [UUID: EPGSource] {
        var map: [UUID: EPGSource] = [:]
        for source in try catalogContext.fetch(FetchDescriptor<EPGSource>()) where source.playlistID == nil {
            map[source.id] = source
        }
        return map
    }

    func fetchEPGSourceMirrors() throws -> [UUID: SyncedEPGSource] {
        var map: [UUID: SyncedEPGSource] = [:]
        for mirror in try cloudContext.fetch(FetchDescriptor<SyncedEPGSource>()) {
            map[mirror.id] = dedupe(mirror, against: map[mirror.id])
        }
        return map
    }

    func dedupe(_ candidate: SyncedEPGSource, against existing: SyncedEPGSource?) -> SyncedEPGSource {
        dedupe(candidate, against: existing, updatedAt: \.updatedAt)
    }

    /// Mirrors for the currently active profile only — inactive profiles' state
    /// must not project onto the (single, active-profile) catalog.
    func fetchContentMirrors() throws -> [String: UserContentState] {
        try fetchMirrors(forProfile: activeProfileID)
    }

    /// Content mirrors belonging to `profileID`, keyed by content id. A legacy
    /// `nil` profileID is treated as the default profile until bootstrap claims
    /// it, so a reconcile that races ahead of bootstrap still behaves correctly.
    func fetchMirrors(forProfile profileID: UUID) throws -> [String: UserContentState] {
        // Filter in SQLite (profileID is indexed) instead of hydrating every
        // profile's mirrors and filtering in Swift. Legacy `nil`-profileID records
        // count as the default profile until bootstrap claims them, so include
        // them only when the default profile is the one being fetched — exactly
        // the previous `(profileID ?? default) == profileID` semantics.
        let includeUnclaimed = profileID == UserProfile.defaultProfileID
        let descriptor = FetchDescriptor<UserContentState>(
            predicate: #Predicate { $0.profileID == profileID || ($0.profileID == nil && includeUnclaimed) }
        )
        var map: [String: UserContentState] = [:]
        for mirror in try cloudContext.fetch(descriptor) {
            map[mirror.contentId] = dedupe(mirror, against: map[mirror.contentId])
        }
        return map
    }

    /// Defensive de-duplication: CloudKit can momentarily surface two records for
    /// one key — keep the most recently updated and delete the loser.
    func dedupe<T: PersistentModel>(_ candidate: T, against existing: T?, updatedAt: (T) -> Date) -> T {
        guard let existing else { return candidate }
        if updatedAt(candidate) > updatedAt(existing) {
            cloudContext.delete(existing)
            return candidate
        }
        cloudContext.delete(candidate)
        return existing
    }

    func dedupe(_ candidate: SyncedPlaylist, against existing: SyncedPlaylist?) -> SyncedPlaylist {
        dedupe(candidate, against: existing, updatedAt: \.updatedAt)
    }

    func dedupe(_ candidate: UserContentState, against existing: UserContentState?) -> UserContentState {
        dedupe(candidate, against: existing, updatedAt: \.updatedAt)
    }

    func fetchLocalContentValues() throws -> [String: LocalContentEntry] {
        var map: [String: LocalContentEntry] = [:]
        try movieEntries().forEach { map[$0] = $1 }
        try seriesEntries().forEach { map[$0] = $1 }
        try episodeEntries().forEach { map[$0] = $1 }
        try liveEntries().forEach { map[$0] = $1 }
        try categoryEntries().forEach { map[$0] = $1 }
        return map
    }

    func movieEntries() throws -> [(String, LocalContentEntry)] {
        let movies = try catalogContext.fetch(FetchDescriptor<Movie>(
            predicate: #Predicate { $0.isFavorite || $0.watchProgress > 0 || $0.isWatched || $0.addedToWatchlistDate != nil || $0.recommendationVoteRaw != 0 }
        ))
        return movies.map { movie in
            (movie.id, LocalContentEntry(
                values: ContentStateValues(
                    watchProgress: movie.watchProgress,
                    isWatched: movie.isWatched,
                    lastWatchedDate: movie.lastWatchedDate,
                    isFavorite: movie.isFavorite,
                    addedToWatchlistDate: movie.addedToWatchlistDate,
                    favoriteOrder: movie.favoriteOrder,
                    recommendationVoteRaw: movie.recommendationVoteRaw
                ),
                kind: .movie,
                model: movie
            ))
        }
    }

    func seriesEntries() throws -> [(String, LocalContentEntry)] {
        let series = try catalogContext.fetch(FetchDescriptor<Series>(
            predicate: #Predicate { $0.isFavorite || $0.addedToWatchlistDate != nil || $0.lastWatchedDate != nil || $0.recommendationVoteRaw != 0 }
        ))
        return series.map { item in
            (item.id, LocalContentEntry(
                values: ContentStateValues(
                    watchProgress: 0,
                    isWatched: false,
                    lastWatchedDate: item.lastWatchedDate,
                    isFavorite: item.isFavorite,
                    addedToWatchlistDate: item.addedToWatchlistDate,
                    favoriteOrder: item.favoriteOrder,
                    recommendationVoteRaw: item.recommendationVoteRaw
                ),
                kind: .series,
                model: item
            ))
        }
    }

    func episodeEntries() throws -> [(String, LocalContentEntry)] {
        let episodes = try catalogContext.fetch(FetchDescriptor<Episode>(
            predicate: #Predicate { $0.watchProgress > 0 || $0.isWatched }
        ))
        return episodes.map { episode in
            (episode.id, LocalContentEntry(
                values: ContentStateValues(
                    watchProgress: episode.watchProgress,
                    isWatched: episode.isWatched,
                    lastWatchedDate: episode.lastWatchedDate,
                    isFavorite: false,
                    addedToWatchlistDate: nil,
                    favoriteOrder: nil
                ),
                kind: .episode,
                model: episode
            ))
        }
    }

    /// Live streams sync their favorite flag/order and their Content Management
    /// visibility (`isHidden`) — channel-surfing "recently watched" and the
    /// per-category `customOrder` stay device-local to avoid mirror bloat (one
    /// record per channel in a reordered category).
    func liveEntries() throws -> [(String, LocalContentEntry)] {
        let streams = try catalogContext.fetch(FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.isFavorite || $0.isHidden }
        ))
        return streams.map { stream in
            (stream.id, LocalContentEntry(
                values: ContentStateValues(
                    watchProgress: 0,
                    isWatched: false,
                    lastWatchedDate: nil,
                    isFavorite: stream.isFavorite,
                    addedToWatchlistDate: nil,
                    favoriteOrder: stream.favoriteOrder,
                    isHidden: stream.isHidden
                ),
                kind: .live,
                model: stream
            ))
        }
    }

    /// Categories sync their Content Management visibility (`isHidden`) and
    /// ordering (`customOrder`). Only customized rows are fetched, so a playlist
    /// the user never touched produces no mirror records. `isRestricted` is
    /// deliberately excluded here: it is a parental control a parent sets *about*
    /// a child profile, not per-profile state, so it syncs on its own
    /// non-profile-scoped channel — see `CloudSyncEngine+Parental`.
    func categoryEntries() throws -> [(String, LocalContentEntry)] {
        let categories = try catalogContext.fetch(FetchDescriptor<Category>(
            predicate: #Predicate { $0.isHidden || $0.customOrder != nil }
        ))
        return categories.map { category in
            (category.id, LocalContentEntry(
                values: ContentStateValues(
                    watchProgress: 0,
                    isWatched: false,
                    lastWatchedDate: nil,
                    isFavorite: false,
                    addedToWatchlistDate: nil,
                    favoriteOrder: nil,
                    isHidden: category.isHidden,
                    customOrder: category.customOrder
                ),
                kind: .category,
                model: category
            ))
        }
    }

    /// Catalog models for `ids` keyed by id — one chunked `IN` fetch per kind
    /// instead of one single-row fetch per id. The pull path resolves a catalog
    /// model for every cloud state it applies, so a fresh device pulling a whole
    /// profile's states (or a profile switch importing its mirrors) would
    /// otherwise issue thousands of individual fetches.
    func fetchCatalogModels(byKind idsByKind: [SyncedContentKind: [String]]) throws -> [String: any PersistentModel] {
        var map: [String: any PersistentModel] = [:]
        for (kind, ids) in idsByKind {
            switch kind {
            case .movie:
                try batchFetch(ids, into: &map, id: \Movie.id) { chunk in
                    #Predicate<Movie> { chunk.contains($0.id) }
                }
            case .series:
                try batchFetch(ids, into: &map, id: \Series.id) { chunk in
                    #Predicate<Series> { chunk.contains($0.id) }
                }
            case .episode:
                try batchFetch(ids, into: &map, id: \Episode.id) { chunk in
                    #Predicate<Episode> { chunk.contains($0.id) }
                }
            case .live:
                try batchFetch(ids, into: &map, id: \LiveStream.id) { chunk in
                    #Predicate<LiveStream> { chunk.contains($0.id) }
                }
            case .category:
                try batchFetch(ids, into: &map, id: \Category.id) { chunk in
                    #Predicate<Category> { chunk.contains($0.id) }
                }
            }
        }
        return map
    }

    /// Keeps each `IN` list comfortably under SQLite's bound-variable cap.
    private static let idChunkSize = 500

    private func batchFetch<T: PersistentModel>(
        _ ids: [String],
        into map: inout [String: any PersistentModel],
        id key: KeyPath<T, String>,
        predicate: (Set<String>) -> Predicate<T>
    ) throws {
        var start = 0
        while start < ids.count {
            let end = min(start + Self.idChunkSize, ids.count)
            let chunk = Set(ids[start ..< end])
            for model in try catalogContext.fetch(FetchDescriptor<T>(predicate: predicate(chunk))) {
                map[model[keyPath: key]] = model
            }
            start = end
        }
    }

    func fetchMovie(_ id: String) throws -> Movie? {
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try catalogContext.fetch(descriptor).first
    }

    func fetchSeries(_ id: String) throws -> Series? {
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try catalogContext.fetch(descriptor).first
    }

    func fetchEpisode(_ id: String) throws -> Episode? {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try catalogContext.fetch(descriptor).first
    }

    func fetchLiveStream(_ id: String) throws -> LiveStream? {
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try catalogContext.fetch(descriptor).first
    }

    func fetchCategory(_ id: String) throws -> Category? {
        var descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try catalogContext.fetch(descriptor).first
    }
}

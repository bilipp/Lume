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
        return map
    }

    func movieEntries() throws -> [(String, LocalContentEntry)] {
        let movies = try catalogContext.fetch(FetchDescriptor<Movie>(
            predicate: #Predicate { $0.isFavorite || $0.watchProgress > 0 || $0.isWatched || $0.addedToWatchlistDate != nil }
        ))
        return movies.map { movie in
            (movie.id, LocalContentEntry(
                values: ContentStateValues(
                    watchProgress: movie.watchProgress,
                    isWatched: movie.isWatched,
                    lastWatchedDate: movie.lastWatchedDate,
                    isFavorite: movie.isFavorite,
                    addedToWatchlistDate: movie.addedToWatchlistDate,
                    favoriteOrder: nil
                ),
                kind: .movie,
                model: movie
            ))
        }
    }

    func seriesEntries() throws -> [(String, LocalContentEntry)] {
        let series = try catalogContext.fetch(FetchDescriptor<Series>(
            predicate: #Predicate { $0.isFavorite || $0.addedToWatchlistDate != nil || $0.lastWatchedDate != nil }
        ))
        return series.map { item in
            (item.id, LocalContentEntry(
                values: ContentStateValues(
                    watchProgress: 0,
                    isWatched: false,
                    lastWatchedDate: item.lastWatchedDate,
                    isFavorite: item.isFavorite,
                    addedToWatchlistDate: item.addedToWatchlistDate,
                    favoriteOrder: nil
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

    /// Live streams sync only their favorite flag/order — channel-surfing
    /// "recently watched" stays device-local to avoid mirror bloat.
    func liveEntries() throws -> [(String, LocalContentEntry)] {
        let streams = try catalogContext.fetch(FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.isFavorite }
        ))
        return streams.map { stream in
            (stream.id, LocalContentEntry(
                values: ContentStateValues(
                    watchProgress: 0,
                    isWatched: false,
                    lastWatchedDate: nil,
                    isFavorite: stream.isFavorite,
                    addedToWatchlistDate: nil,
                    favoriteOrder: stream.favoriteOrder
                ),
                kind: .live,
                model: stream
            ))
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
}

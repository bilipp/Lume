//
//  CloudSyncEngine+Content.swift
//  Lume
//
//  Per-content mutation helpers — projecting a synced `ContentStateValues` onto
//  the matching cloud mirror or local catalog model, and resetting orphaned
//  local state. Split out of CloudSyncEngine.swift to keep that file within the
//  project's line-count cap.
//

import Foundation
import SwiftData

/// Not `private`: profile operations in `CloudSyncEngine+Profiles.swift`
/// reuse these helpers (fetch / reset / apply / value extraction).
extension CloudSyncEngine {
    static func kind(of model: (any PersistentModel)?) -> SyncedContentKind? {
        switch model {
        case is Movie: .movie
        case is Series: .series
        case is Episode: .episode
        case is LiveStream: .live
        case is Category: .category
        default: nil
        }
    }

    func applyContentToCloud(_ value: ContentStateValues?, id: String, kind: SyncedContentKind?, mirror: UserContentState?) {
        guard let value, !value.isEmpty else {
            if let mirror { cloudContext.delete(mirror) }
            return
        }
        let kind = kind ?? mirror?.kind ?? .movie
        if let mirror {
            mirror.profileID = activeProfileID // heals a legacy nil record on first touch
            mirror.kindRaw = kind.rawValue
            mirror.watchProgress = value.watchProgress
            mirror.isWatched = value.isWatched
            mirror.lastWatchedDate = value.lastWatchedDate
            mirror.isFavorite = value.isFavorite
            mirror.addedToWatchlistDate = value.addedToWatchlistDate
            mirror.favoriteOrder = value.favoriteOrder
            mirror.recommendationVoteRaw = value.recommendationVoteRaw
            mirror.isHidden = value.isHidden
            mirror.customOrder = value.customOrder
            mirror.updatedAt = Date()
        } else {
            cloudContext.insert(UserContentState(
                contentId: id,
                kind: kind,
                profileID: activeProfileID,
                watchProgress: value.watchProgress,
                isWatched: value.isWatched,
                lastWatchedDate: value.lastWatchedDate,
                isFavorite: value.isFavorite,
                addedToWatchlistDate: value.addedToWatchlistDate,
                favoriteOrder: value.favoriteOrder,
                recommendationVoteRaw: value.recommendationVoteRaw,
                isHidden: value.isHidden,
                customOrder: value.customOrder
            ))
        }
    }

    /// Applies a cloud value to the matching local catalog item. Returns false
    /// (without touching the shadow) when the catalog item hasn't synced to this
    /// device yet, so the change stays pending for a later pass.
    func applyContentToLocal(_ value: ContentStateValues?, id: String, kind: SyncedContentKind?, loaded: (any PersistentModel)?) throws -> Bool {
        guard let kind else { return true } // nothing to apply (shadow-only id)
        let values = value ?? ContentStateValues(watchProgress: 0, isWatched: false, lastWatchedDate: nil, isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil)

        // Each helper returns false when its catalog item hasn't synced yet, so
        // the change stays pending for a later pass.
        switch kind {
        case .movie: return try applyMovieToLocal(values, id: id, loaded: loaded)
        case .series: return try applySeriesToLocal(values, id: id, loaded: loaded)
        case .episode: return try applyEpisodeToLocal(values, id: id, loaded: loaded)
        case .live: return try applyLiveToLocal(values, id: id, loaded: loaded)
        case .category: return try applyCategoryToLocal(values, id: id, loaded: loaded)
        }
    }

    private func applyMovieToLocal(_ values: ContentStateValues, id: String, loaded: (any PersistentModel)?) throws -> Bool {
        guard let movie = try (loaded as? Movie) ?? fetchMovie(id) else { return false }
        movie.watchProgress = values.watchProgress
        movie.isWatched = values.isWatched
        movie.lastWatchedDate = values.lastWatchedDate
        movie.isFavorite = values.isFavorite
        movie.favoriteOrder = values.favoriteOrder
        movie.addedToWatchlistDate = values.addedToWatchlistDate
        movie.recommendationVoteRaw = values.recommendationVoteRaw
        return true
    }

    private func applySeriesToLocal(_ values: ContentStateValues, id: String, loaded: (any PersistentModel)?) throws -> Bool {
        guard let series = try (loaded as? Series) ?? fetchSeries(id) else { return false }
        series.isFavorite = values.isFavorite
        series.favoriteOrder = values.favoriteOrder
        series.addedToWatchlistDate = values.addedToWatchlistDate
        series.lastWatchedDate = values.lastWatchedDate
        series.recommendationVoteRaw = values.recommendationVoteRaw
        return true
    }

    private func applyEpisodeToLocal(_ values: ContentStateValues, id: String, loaded: (any PersistentModel)?) throws -> Bool {
        guard let episode = try (loaded as? Episode) ?? fetchEpisode(id) else { return false }
        episode.watchProgress = values.watchProgress
        episode.isWatched = values.isWatched
        episode.lastWatchedDate = values.lastWatchedDate
        return true
    }

    private func applyLiveToLocal(_ values: ContentStateValues, id: String, loaded: (any PersistentModel)?) throws -> Bool {
        guard let stream = try (loaded as? LiveStream) ?? fetchLiveStream(id) else { return false }
        stream.isFavorite = values.isFavorite
        stream.favoriteOrder = values.favoriteOrder
        stream.isHidden = values.isHidden
        // `customOrder` (per-category channel order) is intentionally
        // device-local — not pulled from the mirror.
        return true
    }

    private func applyCategoryToLocal(_ values: ContentStateValues, id: String, loaded: (any PersistentModel)?) throws -> Bool {
        guard let category = try (loaded as? Category) ?? fetchCategory(id) else { return false }
        category.isHidden = values.isHidden
        category.customOrder = values.customOrder
        return true
    }

    /// Resets an orphaned local item's user state to defaults so it stops
    /// regenerating cloud records after its playlist was deleted.
    func resetLocalContent(_ entry: LocalContentEntry) {
        switch entry.model {
        case let movie as Movie:
            movie.watchProgress = 0
            movie.isWatched = false
            movie.lastWatchedDate = nil
            movie.isFavorite = false
            movie.favoriteOrder = nil
            movie.addedToWatchlistDate = nil
            movie.recommendationVoteRaw = 0
        case let series as Series:
            series.isFavorite = false
            series.favoriteOrder = nil
            series.addedToWatchlistDate = nil
            series.lastWatchedDate = nil
            series.recommendationVoteRaw = 0
        case let episode as Episode:
            episode.watchProgress = 0
            episode.isWatched = false
            episode.lastWatchedDate = nil
        case let stream as LiveStream:
            stream.isFavorite = false
            stream.favoriteOrder = nil
            stream.isHidden = false
        // `customOrder` is device-local (not projected per profile) — leave it.
        case let category as Category:
            // `isRestricted` is a parental control, not per-profile state: it
            // syncs on its own channel (`CloudSyncEngine+Parental`) and must
            // survive a profile switch — leave it untouched.
            category.isHidden = false
            category.customOrder = nil
        default:
            break
        }
    }
}

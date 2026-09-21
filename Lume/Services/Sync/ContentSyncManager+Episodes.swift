//
//  ContentSyncManager+Episodes.swift
//  Lume
//
//  The lazily-fetched episode path for the Xtream / Stalker pipelines:
//  provider episodes parsed off the main actor, then materialized onto the
//  view context's series. Split out of ContentSyncManager.swift to keep that
//  file within the project's file-length limit.
//

import Foundation
import SwiftData

// MARK: - ParsedEpisode

/// A provider episode parsed off the main actor, ready to be turned into an
/// `Episode` model by the caller on its own context. Value type so it can cross
/// the actor boundary safely.
struct ParsedEpisode {
    let id: String
    let episodeId: String
    let title: String
    let containerExtension: String
    let seasonNum: Int
    let episodeNum: Int
    let added: String?
    let directSource: String?
    let durationSecs: Int?
    let movieImage: String?
    let rating: Double?
    let airDate: String?
    let plot: String?
}

extension Series {
    /// Materializes fetched episodes on `context` and links them to this series,
    /// de-duping against any already present (Episode.id is unique). Mutating the
    /// `episodes` relationship directly updates any observing SwiftUI view, so the
    /// caller must run this on the same context the view renders from.
    ///
    /// Additive on purpose: a refresh merges in episodes the provider has added
    /// since the last fetch and never deletes, so a provider hiccup (a short or
    /// empty `get_series_info` response) can't wipe rows that carry watch
    /// progress. Call only after a *successful* fetch — it stamps the episode
    /// cache, which suppresses further refreshes until it goes stale again.
    func insertEpisodes(_ parsed: [ParsedEpisode], into context: ModelContext) {
        let existingIds = Set(episodes.map(\.id))
        for parsed in parsed where !existingIds.contains(parsed.id) {
            let episode = Episode(
                id: parsed.id,
                episodeId: parsed.episodeId,
                title: parsed.title,
                containerExtension: parsed.containerExtension,
                seasonNum: parsed.seasonNum,
                episodeNum: parsed.episodeNum,
                added: parsed.added,
                directSource: parsed.directSource
            )
            episode.durationSecs = parsed.durationSecs
            episode.movieImage = parsed.movieImage
            episode.rating = parsed.rating
            episode.airDate = parsed.airDate
            episode.plot = parsed.plot
            context.insert(episode)
            episodes.append(episode)
        }
        // A tracker import can only mark episodes that exist, so anything
        // parked for this series is applied here — the one place episodes ever
        // materialize for Xtream and Stalker.
        TraktWatchedImporter.applyPending(to: self)
        SimklWatchedImporter.applyPending(to: self)
        episodesFetchedAt = Date()
        episodesFetchedLastModified = lastModified
        try? context.save()
    }
}

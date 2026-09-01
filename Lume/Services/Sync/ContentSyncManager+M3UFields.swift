//
//  ContentSyncManager+M3UFields.swift
//  Lume
//
//  The fetch-before-write lookups and dirty-checked field application for the
//  m3u pipeline: the counterpart of `existingMovies`/`applyMovieFields` and
//  friends for entries that carry no provider DTO. Split out of
//  ContentSyncManager+M3U.swift, which sits against SwiftLint's file-length
//  limit.
//

import Foundation
import SwiftData

// MARK: - Seeding the import from what the playlist already stores

extension ContentSyncManager {
    /// Primes an import's cross-batch state with what this playlist already
    /// holds: the categories previous syncs created, and the `num` each kind's
    /// next insert should take.
    func seedImportState(_ state: M3UImportState, playlistId: UUID) {
        // Categories from previous syncs are updated in place — re-inserting
        // would be an upsert that wipes isHidden / customOrder.
        for type in CategoryType.allCases {
            let lookup = buildExistingCategoryLookup(
                context: ModelContext(modelContainer), playlistId: playlistId, type: type
            )
            for apiId in lookup.keys {
                state.knownCategories.insert("\(type.rawValue)|\(apiId)")
            }
            state.categoryOrder[type.rawValue] = lookup.count
        }
        seedInsertOrder(playlistId: playlistId, state: state, context: ModelContext(modelContainer))
    }

    /// The `num` values a fresh import should start handing to newly-inserted
    /// rows: one past the highest this playlist already stores, per kind.
    ///
    /// m3u `num` is assigned only on insert (see `M3UImportState`), so it has to
    /// continue the existing sequence rather than restart at the file position —
    /// restarting would hand a prepended entry a `num` that a stored row already
    /// holds, and "Playlist order" would break the tie arbitrarily.
    ///
    /// Three `fetchLimit: 1` reads, once per import. `num` carries no `#Index`,
    /// so each is a filter-then-sort over that playlist's rows of one kind —
    /// tens of milliseconds against an import measured in minutes, and #196
    /// already established that even the ~860 per-batch existing-row lookups are
    /// under 6% of import cost. Not worth an index that every write would pay
    /// for. On a first import all three return 0 and the result is exactly the
    /// file order.
    func seedInsertOrder(playlistId: UUID, state: M3UImportState, context: ModelContext) {
        let prefix = playlistId.uuidString
        var live = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.id.starts(with: prefix) },
            sortBy: [SortDescriptor(\.num, order: .reverse)]
        )
        live.fetchLimit = 1
        var movie = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.id.starts(with: prefix) },
            sortBy: [SortDescriptor(\.num, order: .reverse)]
        )
        movie.fetchLimit = 1
        var series = FetchDescriptor<Series>(
            predicate: #Predicate { $0.id.starts(with: prefix) },
            sortBy: [SortDescriptor(\.num, order: .reverse)]
        )
        series.fetchLimit = 1

        let highestLive = (try? context.fetch(live))?.first?.num
        let highestMovie = (try? context.fetch(movie))?.first?.num
        let highestSeries = (try? context.fetch(series))?.first?.num
        state.liveNum = highestLive.map { $0 + 1 } ?? 0
        state.movieNum = highestMovie.map { $0 + 1 } ?? 0
        state.seriesNum = highestSeries.map { $0 + 1 } ?? 0
    }
}

// MARK: - Existing-row lookups for in-place upsert

extension ContentSyncManager {
    /// The m3u counterpart of `existingSeries(in:playlistId:context:)`: a batch
    /// names the same series once per episode, so the ids are deduplicated
    /// before the fetch.
    func existingSeries(ids: [String], context: ModelContext) -> [String: Series] {
        let uniqueIds = Array(Set(ids))
        var lookup: [String: Series] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { uniqueIds.contains($0.id) })
        )) ?? []
        for series in fetched {
            lookup[series.id] = series
        }
        return lookup
    }

    func existingEpisodes(ids: [String], context: ModelContext) -> [String: Episode] {
        var lookup: [String: Episode] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<Episode>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for episode in fetched {
            lookup[episode.id] = episode
        }
        return lookup
    }
}

// MARK: - Dirty-checked field application

extension ContentSyncManager {
    /// Copies the provider-owned fields of an m3u entry onto an existing or
    /// freshly-inserted `LiveStream`, leaving user state intact.
    ///
    /// Every write is guarded by an inequality test. SwiftData marks a row dirty
    /// on *assignment*, not on change, so re-writing an identical value makes
    /// `save()` rewrite (and re-index) the whole row — the dominant cost of a
    /// re-sync where almost nothing changed.
    ///
    /// The guards must compare exactly what the unguarded assignment would have
    /// stored: `nil` and `""` are distinct values here (an entry with no
    /// `tvg-logo` and one with `tvg-logo=""` are different), and no
    /// normalisation applies. Any tolerance silently *stops* applying a
    /// legitimate provider update, which is harder to notice than the reverse.
    ///
    /// `num` is deliberately absent: it is assigned only on insert (see the
    /// call site in `importLive`).
    ///
    /// Unlike the Xtream `applyLiveStreamFields` this needs no
    /// `cyclomatic_complexity` opt-out — m3u carries a third of the fields, so
    /// the guards stay under the threshold and SwiftLint's
    /// `superfluous_disable_command` rejects the opt-out.
    func applyM3ULiveStreamFields(from entry: M3UEntry, to stream: LiveStream, categoryId: String) {
        if stream.name != entry.name { stream.name = entry.name }
        if stream.streamIcon != entry.logo { stream.streamIcon = entry.logo }
        if stream.epgChannelId != entry.tvgId { stream.epgChannelId = entry.tvgId }
        if stream.directURL != entry.url { stream.directURL = entry.url }
        if stream.categoryId != categoryId { stream.categoryId = categoryId }
    }

    /// Copies the provider-owned fields of an m3u entry onto an existing or
    /// freshly-inserted `Movie`, leaving user state and TMDB enrichment intact.
    ///
    /// Dirty-checked for the same reason, and under the same exactness rules, as
    /// `applyM3ULiveStreamFields`. `num` is likewise assigned only on insert
    /// (see the call site in `importMovies`).
    func applyM3UMovieFields(from entry: M3UEntry, to movie: Movie, categoryId: String) {
        if movie.name != entry.name { movie.name = entry.name }
        if movie.streamIcon != entry.logo { movie.streamIcon = entry.logo }
        if movie.directURL != entry.url { movie.directURL = entry.url }
        let containerExtension = M3UClassifier.pathExtension(of: entry.url)
        if movie.containerExtension != containerExtension { movie.containerExtension = containerExtension }
        if movie.categoryId != categoryId { movie.categoryId = categoryId }
    }

    /// Copies the fields an m3u episode entry carries for its parent `Series`.
    ///
    /// m3u has no series-level metadata, so this is the group title and the
    /// first episode artwork that turns up. `cover` is seeded once and never
    /// overwritten — a later episode's logo must not replace it, and TMDB
    /// enrichment owns it from then on. `num` is assigned only on insert.
    ///
    /// Dirty-checked for the same reason, and under the same exactness rules, as
    /// `applyM3ULiveStreamFields`.
    func applyM3USeriesFields(from entry: M3UEntry, to series: Series, categoryId: String) {
        if series.categoryId != categoryId { series.categoryId = categoryId }
        if series.cover == nil, entry.logo != nil { series.cover = entry.logo }
    }

    /// Copies the provider-owned fields of an m3u entry onto an existing or
    /// freshly-inserted `Episode`, leaving watch progress and downloads intact.
    ///
    /// `containerExtension`, `seasonNum` and `episodeNum` are part of the
    /// episode's identity and are set at construction only.
    ///
    /// Dirty-checked for the same reason, and under the same exactness rules, as
    /// `applyM3ULiveStreamFields`.
    func applyM3UEpisodeFields(from entry: M3UEntry, title: String, to episode: Episode) {
        if episode.title != title { episode.title = title }
        if episode.directSource != entry.url { episode.directSource = entry.url }
        if episode.movieImage != entry.logo { episode.movieImage = entry.logo }
    }
}

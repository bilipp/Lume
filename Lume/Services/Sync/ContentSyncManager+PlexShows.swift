//
//  ContentSyncManager+PlexShows.swift
//  Lume
//
//  The show and episode half of the Plex pipeline, split from
//  `ContentSyncManager+Plex.swift` to keep both files within the project's
//  size limit. Shows are imported first so the section's single flat episode
//  query can link against them.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    // MARK: - Series & episodes

    func syncPlexShows(scope: PlexSectionScope, seenSeries: inout Set<String>, seenEpisodes: inout Set<String>, progress: SyncProgress?) async throws {
        // Series shells first, so episodes below can link against them.
        var showsByRatingKey: [String: PlexMetadata] = [:]
        var seen = seenSeries
        _ = try await pageThroughPlexItems(type: PlexClient.showType, scope: scope, progress: nil, unit: "series") { items in
            seen.formUnion(upsertPlexSeries(items, scope: scope))
            for item in items {
                showsByRatingKey[item.ratingKey] = item
            }
        }

        // Then every episode in the section, grouped by its show. An episode
        // whose show shell is missing still imports under a shell built from
        // its `grandparentTitle` so no playable file is ever dropped.
        var seenEp = seenEpisodes
        let shells = showsByRatingKey
        let episodeCount = try await pageThroughPlexItems(
            type: PlexClient.episodeType, scope: scope, progress: progress, unit: "episode(s)"
        ) { items in
            let (series, episodes) = upsertPlexEpisodes(items, showShells: shells, scope: scope)
            seen.formUnion(series)
            seenEp.formUnion(episodes)
        }
        seenSeries = seen
        seenEpisodes = seenEp
        Logger.database.info("Plex shows synced for section \(scope.section.title, privacy: .public): \(episodeCount, privacy: .public) episode(s)")
    }

    private func upsertPlexSeries(_ items: [PlexMetadata], scope: PlexSectionScope) -> Set<String> {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = items.map { scope.idPrefix + $0.ratingKey }
        let lookup = existingSeries(ids: ids, context: context)

        for item in items {
            let id = scope.idPrefix + item.ratingKey
            let series: Series
            if let found = lookup[id] {
                series = found
            } else {
                series = Series(id: id, seriesId: Self.plexStreamId(item.ratingKey), name: item.title ?? "")
                context.insert(series)
            }
            applyPlexSeriesFields(item, to: series, scope: scope)
        }
        if context.hasChanges {
            try? context.save()
        }
        return Set(ids)
    }

    private func applyPlexSeriesFields(_ item: PlexMetadata, to series: Series, scope: PlexSectionScope) {
        let name = item.title ?? ""
        if series.name != name {
            series.name = name
        }
        if series.categoryId != scope.categoryId {
            series.categoryId = scope.categoryId
        }
        if let thumb = item.thumb,
           let url = PlexClient.imageURL(server: scope.server, path: thumb, token: scope.token)?.absoluteString,
           series.cover != url
        {
            series.cover = url
        }
        if series.plot != item.summary {
            series.plot = item.summary
        }
        if series.genre != item.genreList {
            series.genre = item.genreList
        }
        if series.releaseDate != item.originallyAvailableAt {
            series.releaseDate = item.originallyAvailableAt
        }
        if let rating = (item.rating ?? item.audienceRating).map({ String($0) }), series.rating != rating {
            series.rating = rating
        }
        if let tmdb = item.providerId("tmdb"), series.tmdb != tmdb {
            series.tmdb = tmdb
        }
        if let imdb = item.providerId("imdb"), series.imdbId != imdb {
            series.imdbId = imdb
        }
    }

    private func upsertPlexEpisodes(_ items: [PlexMetadata], showShells: [String: PlexMetadata], scope: PlexSectionScope) -> (series: Set<String>, episodes: Set<String>) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        // The series rows these episodes link against — shells already stored
        // plus fallback shells for episodes whose show has none.
        var seriesIds: Set<String> = []
        for item in items {
            seriesIds.insert(scope.idPrefix + (item.grandparentRatingKey ?? item.ratingKey))
        }
        var seriesLookup = existingSeries(ids: Array(seriesIds), context: context)

        let episodeIds = items.map { scope.idPrefix + "episode-" + $0.ratingKey }
        let episodeLookup = existingEpisodes(ids: episodeIds, context: context)

        var seenSeries = Set<String>()
        for item in items {
            let series = plexSeriesRow(for: item, showShells: showShells, scope: scope, lookup: &seriesLookup, context: context)
            seenSeries.insert(series.id)
            let episode = plexEpisodeRow(for: item, series: series, lookup: episodeLookup, scope: scope, context: context)
            applyPlexEpisodeFields(item, to: episode, series: series, scope: scope)
        }
        if context.hasChanges {
            try? context.save()
        }
        return (seenSeries, Set(episodeIds))
    }

    /// The stored (or freshly built) series row an episode links against. A
    /// missing shell is built from the episode's `grandparentTitle` so no
    /// playable file is ever dropped.
    private func plexSeriesRow(
        for item: PlexMetadata,
        showShells: [String: PlexMetadata],
        scope: PlexSectionScope,
        lookup: inout [String: Series],
        context: ModelContext
    ) -> Series {
        let showKey = item.grandparentRatingKey ?? item.ratingKey
        let seriesId = scope.idPrefix + showKey
        if let found = lookup[seriesId] {
            return found
        }
        let shellName = item.grandparentTitle ?? showShells[showKey]?.title ?? item.title ?? ""
        let series = Series(id: seriesId, seriesId: Self.plexStreamId(showKey), name: shellName)
        if let shell = showShells[showKey] {
            applyPlexSeriesFields(shell, to: series, scope: scope)
        } else if series.categoryId != scope.categoryId {
            series.categoryId = scope.categoryId
        }
        context.insert(series)
        lookup[seriesId] = series
        return series
    }

    private func plexEpisodeRow(
        for item: PlexMetadata,
        series: Series,
        lookup: [String: Episode],
        scope: PlexSectionScope,
        context: ModelContext
    ) -> Episode {
        let id = scope.idPrefix + "episode-" + item.ratingKey
        if let found = lookup[id] {
            // A server can re-file an episode under a different series — a
            // corrected scan, a merged show. Re-parent it, or the prune below
            // deletes the shell it is still attached to and cascades this row
            // away with it, losing the viewer's progress on an episode the
            // server still lists.
            if found.series?.id != series.id {
                found.series = series
            }
            return found
        }
        let episode = Episode(
            id: id, episodeId: item.ratingKey, title: item.title ?? "",
            containerExtension: item.container?.lowercased() ?? "mkv",
            seasonNum: item.parentIndex ?? 1, episodeNum: item.index ?? 0
        )
        context.insert(episode)
        episode.series = series
        return episode
    }

    private func applyPlexEpisodeFields(_ item: PlexMetadata, to episode: Episode, series: Series, scope: PlexSectionScope) {
        applyPlexEpisodeIdentity(item, to: episode, scope: scope)
        applyPlexEpisodeMetadata(item, to: episode, series: series, scope: scope)
    }

    private func applyPlexEpisodeIdentity(_ item: PlexMetadata, to episode: Episode, scope: PlexSectionScope) {
        let title = item.title ?? ""
        if episode.title != title {
            episode.title = title
        }
        if let season = item.parentIndex, episode.seasonNum != season {
            episode.seasonNum = season
        }
        if let number = item.index, episode.episodeNum != number {
            episode.episodeNum = number
        }
        if let part = item.partKey,
           let url = PlexClient.streamURL(server: scope.server, partKey: part)?.absoluteString,
           episode.directSource != url
        {
            episode.directSource = url
        }
        if let container = item.container?.lowercased(), episode.containerExtension != container {
            episode.containerExtension = container
        }
    }

    private func applyPlexEpisodeMetadata(_ item: PlexMetadata, to episode: Episode, series: Series, scope: PlexSectionScope) {
        let image: String? = {
            if let thumb = item.thumb {
                return PlexClient.imageURL(server: scope.server, path: thumb, token: scope.token)?.absoluteString
            }
            return series.cover
        }()
        if episode.movieImage != image {
            episode.movieImage = image
        }
        if episode.durationSecs != item.durationSecs {
            episode.durationSecs = item.durationSecs
        }
        let rating = item.rating ?? item.audienceRating
        if episode.rating != rating {
            episode.rating = rating
        }
        if episode.airDate != item.originallyAvailableAt {
            episode.airDate = item.originallyAvailableAt
        }
        if episode.plot != item.summary {
            episode.plot = item.summary
        }
    }

    func prunePlexSeries(playlistId: UUID, seenSeries: Set<String>, seenEpisodes: Set<String>, fetched: Bool) {
        guard fetched else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let prefix = playlistId.uuidString
        let rows = (try? context.fetch(FetchDescriptor<Series>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        ))) ?? []
        for series in rows where series.id.contains("-plex-") {
            if seenSeries.contains(series.id) {
                // The shell survives, but dropped episodes don't: delete them
                // explicitly (no cascade from a surviving parent).
                for episode in series.episodes where !seenEpisodes.contains(episode.id) {
                    context.delete(episode)
                }
            } else {
                // Episodes and cast cascade from the deleted series.
                context.delete(series)
            }
        }
        if context.hasChanges {
            try? context.save()
        }
    }
}

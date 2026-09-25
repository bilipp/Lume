//
//  ContentSyncManager+MediaServerShows.swift
//  Lume
//
//  The series and episode half of the Jellyfin/Emby pipeline, split from
//  `ContentSyncManager+MediaServer.swift` to keep both files within the
//  project's size limit. Shells are imported first so episodes can link
//  against them; an episode whose `SeriesId` has no shell is matched on its
//  `SeriesName` instead (see `JellyfinShellIndex`).
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    // MARK: - Series & episodes

    func syncJellyfinShows(scope: JellyfinViewScope, seenSeries: inout Set<String>, seenEpisodes: inout Set<String>, progress: SyncProgress?) async throws {
        // Series shells first, so episodes below can link against them.
        var shells = JellyfinShellIndex()
        var seen = seenSeries
        _ = try await pageThroughJellyfinItems(types: ["Series"], scope: scope, progress: nil, unit: "series") { items in
            seen.formUnion(upsertJellyfinSeries(items, scope: scope))
            shells.insert(items)
        }

        // Then every episode, grouped by its series. An episode whose series
        // shell is missing (a stale `SeriesId`, or a library the server filed
        // oddly) still imports, under the shell its `SeriesName` names — see
        // `JellyfinShellIndex` — so no playable file is ever dropped and a
        // mis-scanned library does not fan out into one show per file.
        var seenEp = seenEpisodes
        let resolvedShells = shells
        let episodeCount = try await pageThroughJellyfinItems(types: ["Episode"], scope: scope, progress: progress, unit: "episode(s)") { items in
            let (series, episodes) = upsertJellyfinEpisodes(items, seriesShells: resolvedShells, scope: scope)
            seen.formUnion(series)
            seenEp.formUnion(episodes)
        }
        seenSeries = seen
        seenEpisodes = seenEp
        Logger.database.info("\(scope.flavor.displayName, privacy: .public) shows synced for library \(scope.view.name, privacy: .public): \(episodeCount, privacy: .public) episode(s)")
    }

    private func upsertJellyfinSeries(_ items: [JellyfinItem], scope: JellyfinViewScope) -> Set<String> {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = items.map { scope.idPrefix + $0.id }
        let lookup = existingSeries(ids: ids, context: context)

        for item in items {
            let id = scope.idPrefix + item.id
            let series: Series
            if let found = lookup[id] {
                series = found
            } else {
                series = Series(id: id, seriesId: Self.mediaServerHash(item.id), name: item.name ?? "")
                context.insert(series)
            }
            applyJellyfinSeriesFields(item, to: series, scope: scope)
        }
        if context.hasChanges {
            try? context.save()
        }
        return Set(ids)
    }

    private func applyJellyfinSeriesFields(_ item: JellyfinItem, to series: Series, scope: JellyfinViewScope) {
        let name = item.name ?? ""
        if series.name != name {
            series.name = name
        }
        if series.categoryId != scope.categoryId {
            series.categoryId = scope.categoryId
        }
        if let tag = item.primaryImageTag,
           let url = JellyfinClient.imageURL(server: scope.server, itemId: item.id, tag: tag, token: scope.session.accessToken)?.absoluteString,
           series.cover != url
        {
            series.cover = url
        }
        if series.plot != item.overview {
            series.plot = item.overview
        }
        let genre = item.genres?.joined(separator: ", ")
        if series.genre != genre {
            series.genre = genre
        }
        let release = item.premiereDate.map { String($0.prefix(10)) }
        if series.releaseDate != release {
            series.releaseDate = release
        }
        if let rating = item.communityRating.map({ String($0) }),
           series.rating != rating
        {
            series.rating = rating
        }
        if let tmdb = item.providerIds?["Tmdb"], series.tmdb != tmdb {
            series.tmdb = tmdb
        }
        if let imdb = item.providerIds?["Imdb"], series.imdbId != imdb {
            series.imdbId = imdb
        }
    }

    /// The series shells of one library, indexed the two ways an episode can
    /// be matched to them.
    ///
    /// The name index exists because a mis-scanned library is common in the
    /// wild: a server can hand every loose episode file its own `SeriesId`
    /// while they all report the same `SeriesName`, and only one of those ids
    /// has a real `Series` item behind it. Keying purely on the id would then
    /// produce one single-episode show per file.
    private struct JellyfinShellIndex {
        var byId: [String: JellyfinItem] = [:]
        var byName: [String: JellyfinItem] = [:]

        mutating func insert(_ items: [JellyfinItem]) {
            for item in items {
                byId[item.id] = item
                if let name = item.name, !name.isEmpty {
                    byName[name] = item
                }
            }
        }

        /// The server-side id an episode's series row is keyed by. Prefers the
        /// episode's own `SeriesId` when a shell backs it, then a shell with
        /// the same `SeriesName`, then the name itself so same-named episodes
        /// still land in one row, and only then the episode's own id.
        func shellKey(for item: JellyfinItem) -> String {
            if let seriesId = item.seriesId, byId[seriesId] != nil {
                return seriesId
            }
            if let name = item.seriesName, !name.isEmpty {
                return byName[name]?.id ?? "name-\(ContentSyncManager.mediaServerHash(name))"
            }
            return item.seriesId ?? item.id
        }
    }

    private func upsertJellyfinEpisodes(_ items: [JellyfinItem], seriesShells: JellyfinShellIndex, scope: JellyfinViewScope) -> (series: Set<String>, episodes: Set<String>) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        // The series rows these episodes link against — shells already stored
        // plus fallback shells for episodes whose `SeriesId` has no shell.
        let seriesIds = Set(items.map { scope.idPrefix + seriesShells.shellKey(for: $0) })
        var seriesLookup = existingSeries(ids: Array(seriesIds), context: context)

        let episodeIds = items.map { scope.idPrefix + "episode-" + $0.id }
        let episodeLookup = existingEpisodes(ids: episodeIds, context: context)

        var seenSeries = Set<String>()
        for item in items {
            let series = seriesRow(for: item, seriesShells: seriesShells, scope: scope, lookup: &seriesLookup, context: context)
            seenSeries.insert(series.id)
            let episode = episodeRow(for: item, series: series, lookup: episodeLookup, scope: scope, context: context)
            applyJellyfinEpisodeFields(item, to: episode, series: series, scope: scope)
        }
        if context.hasChanges {
            try? context.save()
        }
        return (seenSeries, Set(episodeIds))
    }

    /// The stored (or freshly built) series row an episode links against. A
    /// missing shell is built from the episode's `SeriesName` so no playable
    /// file is ever dropped for a stale `SeriesId`.
    private func seriesRow(
        for item: JellyfinItem,
        seriesShells: JellyfinShellIndex,
        scope: JellyfinViewScope,
        lookup: inout [String: Series],
        context: ModelContext
    ) -> Series {
        let shellJellyfinId = seriesShells.shellKey(for: item)
        let seriesId = scope.idPrefix + shellJellyfinId
        if let found = lookup[seriesId] {
            return found
        }
        let shellName = item.seriesName ?? seriesShells.byId[shellJellyfinId]?.name ?? item.name ?? ""
        let series = Series(id: seriesId, seriesId: Self.mediaServerHash(shellJellyfinId), name: shellName)
        if let shell = seriesShells.byId[shellJellyfinId] {
            applyJellyfinSeriesFields(shell, to: series, scope: scope)
        } else if series.categoryId != scope.categoryId {
            series.categoryId = scope.categoryId
        }
        context.insert(series)
        lookup[seriesId] = series
        return series
    }

    private func episodeRow(
        for item: JellyfinItem,
        series: Series,
        lookup: [String: Episode],
        scope: JellyfinViewScope,
        context: ModelContext
    ) -> Episode {
        let id = scope.idPrefix + "episode-" + item.id
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
            id: id, episodeId: item.id, title: item.name ?? "",
            containerExtension: item.container?.lowercased() ?? "mkv",
            seasonNum: item.parentIndexNumber ?? 1, episodeNum: item.indexNumber ?? 0
        )
        context.insert(episode)
        episode.series = series
        return episode
    }

    private func applyJellyfinEpisodeFields(_ item: JellyfinItem, to episode: Episode, series: Series, scope: JellyfinViewScope) {
        applyJellyfinEpisodeIdentity(item, to: episode, scope: scope)
        applyJellyfinEpisodeMetadata(item, to: episode, series: series, scope: scope)
    }

    private func applyJellyfinEpisodeIdentity(_ item: JellyfinItem, to episode: Episode, scope: JellyfinViewScope) {
        let title = item.name ?? ""
        if episode.title != title {
            episode.title = title
        }
        if let season = item.parentIndexNumber, episode.seasonNum != season {
            episode.seasonNum = season
        }
        if let number = item.indexNumber, episode.episodeNum != number {
            episode.episodeNum = number
        }
        if let url = JellyfinClient.streamURL(server: scope.server, itemId: item.id)?.absoluteString,
           episode.directSource != url
        {
            episode.directSource = url
        }
        if let container = item.container?.lowercased(), episode.containerExtension != container {
            episode.containerExtension = container
        }
    }

    private func applyJellyfinEpisodeMetadata(_ item: JellyfinItem, to episode: Episode, series: Series, scope: JellyfinViewScope) {
        let image: String? = {
            if let tag = item.primaryImageTag {
                return JellyfinClient.imageURL(server: scope.server, itemId: item.id, tag: tag, token: scope.session.accessToken)?.absoluteString
            }
            return series.cover
        }()
        if episode.movieImage != image {
            episode.movieImage = image
        }
        if episode.durationSecs != item.durationSecs {
            episode.durationSecs = item.durationSecs
        }
        if episode.rating != item.communityRating {
            episode.rating = item.communityRating
        }
        let airDate = item.premiereDate.map { String($0.prefix(10)) }
        if episode.airDate != airDate {
            episode.airDate = airDate
        }
        if episode.plot != item.overview {
            episode.plot = item.overview
        }
    }

    func pruneJellyfinSeries(playlistId: UUID, flavor: MediaServerFlavor, seenSeries: Set<String>, seenEpisodes: Set<String>, fetched: Bool) {
        guard fetched else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let prefix = playlistId.uuidString
        let rows = (try? context.fetch(FetchDescriptor<Series>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        ))) ?? []
        let infix = "-\(flavor.idInfix)-"
        for series in rows where series.id.contains(infix) {
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

    /// Stable string→Int for the `streamId`/`seriesId` columns a media server
    /// has no number for. FNV-1a, not `Hasher` — the latter is seeded per
    /// process, so ids would change on every launch and orphan user state.
    /// Only ever used as an opaque key: playback builds from `directURL`.
    nonisolated static func mediaServerHash(_ string: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(truncatingIfNeeded: Int64(bitPattern: hash & 0x7FFF_FFFF_FFFF_FFFF))
    }
}

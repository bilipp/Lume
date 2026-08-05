//
//  ContentSyncManager+M3U.swift
//  Lume
//
//  The m3u sync pipeline: download the playlist file, stream-parse it in
//  batches, classify every entry as live / movie / series episode, and upsert
//  into the same SwiftData models the Xtream pipeline fills — so every view
//  (browsing, search, favorites, EPG) works identically for both source types.
//

import Foundation
import OSLog
import SwiftData

// MARK: - Classification

/// Decides what kind of content an m3u entry is. m3u playlists mix live
/// channels, movies and series episodes in one flat list, so we classify by
/// the signals providers actually emit, in priority order: a season/episode
/// token in the title; an explicit `type="video"` attribute marking VOD; then
/// the URL shape — Xtream-style `/movie/`–`/series/` paths or a video-file
/// extension mark VOD, while live streaming endpoints (`/channel/`–`/live/`
/// paths, an `index.*` segment filename, or a `.ts`/`.m3u8`/no extension) are
/// live. The live-endpoint signal is checked *before* the extension test
/// because some providers serve live channels through `…/index.mpeg`-style
/// URLs whose extension would otherwise read as on-demand video; the `type`
/// attribute, when present, is the only thing distinguishing a movie from a
/// live channel for providers that serve both through that same endpoint shape.
nonisolated enum M3UClassifier {
    nonisolated enum Kind: Equatable {
        case live
        case movie
        case episode(series: String, season: Int, episode: Int)
    }

    /// File extensions that mark an entry as on-demand video. Deliberately
    /// excludes `ts` and `m3u8`, which are live/HLS container formats.
    static let vodExtensions: Set<String> = [
        "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg"
    ]

    /// URL path segments that mark a live streaming endpoint — the live-side
    /// mirror of the `/movie/`–`/series/` VOD markers.
    static let liveStreamPathMarkers = ["/channel/", "/live/", "/stream/"]

    /// Explicit `type="…"` values that mark an entry as on-demand video. Some
    /// providers serve live channels and movies through identical URLs and
    /// only this attribute tells them apart.
    static let vodTypeMarkers: Set<String> = ["video", "movie", "vod"]

    static func classify(_ entry: M3UEntry) -> Kind {
        if let info = episodeInfo(in: entry.name) {
            return .episode(series: info.series, season: info.season, episode: info.episode)
        }

        // An explicit VOD `type` is the strongest signal — it wins over the URL
        // heuristics, which can't distinguish live from on-demand when a
        // provider serves both through the same `…/index.mpeg` endpoint shape.
        if let type = entry.type?.lowercased(), vodTypeMarkers.contains(type) {
            return .movie
        }

        let lowerURL = entry.url.lowercased()
        if lowerURL.contains("/movie/") || lowerURL.contains("/series/") {
            return .movie
        }
        if isLiveStreamURL(lowerURL) {
            return .live
        }
        if let ext = pathExtension(of: lowerURL), vodExtensions.contains(ext) {
            return .movie
        }
        return .live
    }

    /// Whether a URL is a live streaming endpoint rather than a VOD file.
    /// Two signals: a known live path segment, or an `index.*` filename — the
    /// streaming-manifest convention IPTV channels use (e.g.
    /// `…/channel/<id>/index.mpeg`), as opposed to a per-title VOD filename.
    /// Expects an already-lowercased URL.
    static func isLiveStreamURL(_ lowerURL: String) -> Bool {
        if liveStreamPathMarkers.contains(where: { lowerURL.contains($0) }) {
            return true
        }
        var path = Substring(lowerURL)
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = path[..<cut]
        }
        let filenameStart = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        return path[filenameStart...].hasPrefix("index.")
    }

    /// Finds the first `SxxExx` / `NxM` token in a title and splits it into the
    /// series name (everything before the token) and season/episode numbers.
    /// Mirrors `ContentSyncManager.cleanEpisodeTitle`'s token grammar.
    static func episodeInfo(in name: String) -> (series: String, season: Int, episode: Int)? {
        let pattern = #"(?i)\bS\d{1,3}\s*E\d{1,4}\b|\b\d{1,3}x\d{1,4}\b"#
        guard let match = name.range(of: pattern, options: .regularExpression) else {
            return nil
        }

        let token = name[match].lowercased().filter { !$0.isWhitespace }
        let season: Int?
        let episode: Int?
        if token.hasPrefix("s"), let eIndex = token.firstIndex(of: "e") {
            season = Int(token[token.index(after: token.startIndex) ..< eIndex])
            episode = Int(token[token.index(after: eIndex)...])
        } else if let xIndex = token.firstIndex(of: "x") {
            season = Int(token[..<xIndex])
            episode = Int(token[token.index(after: xIndex)...])
            // The bare NxM form is ambiguous with video resolutions
            // ("640x480") in channel names; no show has hundreds of seasons.
            if let season, season > 100 { return nil }
        } else {
            return nil
        }
        guard let season, let episode else { return nil }

        let separators = CharacterSet(charactersIn: " -–—·:|.").union(.whitespacesAndNewlines)
        var series = String(name[..<match.lowerBound]).trimmingCharacters(in: separators)
        if series.isEmpty {
            // Token-first titles ("S01E01 Pilot"): fall back to whatever
            // follows so episodes still cluster under a stable name.
            series = String(name[match.upperBound...]).trimmingCharacters(in: separators)
        }
        guard !series.isEmpty else { return nil }
        return (series, season, episode)
    }

    /// The path extension of a URL string, ignoring query and fragment.
    /// String-based (not `URL`) because it runs for every entry of very large
    /// playlists, and provider URLs aren't always RFC-valid.
    static func pathExtension(of urlString: String) -> String? {
        var path = Substring(urlString)
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = path[..<cut]
        }
        guard let dot = path.lastIndex(of: "."),
              let slash = path.lastIndex(of: "/"),
              dot > slash
        else { return nil }
        let ext = path[path.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return ext.lowercased()
    }
}

// MARK: - Identity

/// Stable identity for m3u content. m3u entries have no provider IDs, so the
/// stream URL is the identity: it's hashed with FNV-1a 64 (deterministic
/// across launches — unlike `Hashable`'s seeded `hashValue`) into the same
/// id/streamId shapes the Xtream pipeline uses, keeping re-syncs idempotent.
nonisolated enum M3UIdentity {
    static func hash64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Compact string key for composing element ids.
    static func key(for string: String) -> String {
        String(hash64(string), radix: 36)
    }

    /// Positive `Int` for model fields that mirror Xtream's numeric stream ids.
    static func numericId(for string: String) -> Int {
        Int(bitPattern: UInt(truncatingIfNeeded: hash64(string)) & 0x7FFF_FFFF_FFFF_FFFF)
    }
}

// MARK: - Import state

/// Mutable registries that live across import batches: which categories exist,
/// which series have been created, and running provider-order counters.
private final nonisolated class M3UImportState {
    /// Ensured category unique-ids, keyed by "\(typeRaw)|\(groupName)".
    var knownCategories: Set<String> = []
    /// Next first-appearance sort order per category type.
    var categoryOrder: [String: Int] = [:]
    /// Running provider-order counters.
    var liveNum = 0
    var movieNum = 0
    var seriesNum = 0

    var importedLive = 0
    var importedMovies = 0
    var importedEpisodes = 0

    /// Ids seen this sync, accumulated across batches so a post-import sweep can
    /// prune rows the file no longer contains. Categories keyed "\(typeRaw)|\(apiId)".
    var seenLiveIds: Set<String> = []
    var seenMovieIds: Set<String> = []
    var seenSeriesIds: Set<String> = []
    var seenEpisodeIds: Set<String> = []
    var seenCategoryKeys: Set<String> = []

    /// First error hit inside a batch; aborts the remaining batches.
    var firstError: Error?

    var totalImported: Int {
        importedLive + importedMovies + importedEpisodes
    }
}

nonisolated struct M3UImportSummary {
    var liveCount = 0
    var movieCount = 0
    var episodeCount = 0
    var headerEPGURL: String?
}

// MARK: - Sync pipeline

extension ContentSyncManager {
    private static let uncategorizedGroup = "Uncategorized"

    /// The m3u pipeline: download → classify/import → EPG.
    func performM3USync(playlist: Playlist, playlistId: UUID, progress: SyncProgress?) async throws {
        let serverURL = playlist.serverURL
        let storedEPGURL = playlist.epgURL
        let client = M3UClient()

        await progress?.start(.playlistDownload)
        // Local imported files are parsed in place; only downloads are temp
        // files we own and must clean up.
        let isRemote = !(URL(string: serverURL)?.isFileURL ?? false)
        let downloadInterval = Perf.begin(.m3uDownload)
        let fileURL = try await client.downloadPlaylist(from: serverURL)
        Perf.end(downloadInterval)
        defer { if isRemote { try? FileManager.default.removeItem(at: fileURL) } }
        await progress?.complete(.playlistDownload)

        await progress?.start(.playlistImport)
        // Download and import are separate intervals on purpose: profiling a
        // 600k-entry playlist showed the SwiftData import — not the download —
        // owning the multi-minute wait, and one combined number hid that.
        let importInterval = Perf.begin(.m3uImport)
        let summary = try importM3UFile(fileURL, playlistId: playlistId, progress: progress)
        Perf.end(importInterval)
        Logger.database.info(
            "m3u import finished: \(summary.liveCount) live, \(summary.movieCount) movies, \(summary.episodeCount) episodes"
        )
        await progress?.update(detail: "\(summary.liveCount + summary.movieCount + summary.episodeCount) items", fraction: 1)
        await progress?.complete(.playlistImport)

        // When the user didn't supply a guide URL, adopt (and remember) the
        // playlist's own url-tvg header so its EPG source is configured
        // automatically. The guide itself is fetched separately by EPGSyncManager.
        if storedEPGURL == nil, let discovered = summary.headerEPGURL {
            persistDiscoveredEPGURL(discovered, playlistId: playlistId)
        }

        markPlaylistUpdated(playlistId)
    }

    /// Stream-parses the playlist file and upserts entries batch by batch.
    /// Runs synchronously on the actor — the same shape as the Xtream batch
    /// loops — with one fresh, autosave-off context per batch so memory stays
    /// flat no matter how large the playlist is.
    private func importM3UFile(_ fileURL: URL, playlistId: UUID, progress: SyncProgress?) throws -> M3UImportSummary {
        let state = M3UImportState()

        // Seed the category registry with categories from previous syncs so
        // they are updated in place (re-inserting would be an upsert that
        // wipes isHidden / customOrder).
        for type in CategoryType.allCases {
            let lookup = buildExistingCategoryLookup(
                context: ModelContext(modelContainer), playlistId: playlistId, type: type
            )
            for apiId in lookup.keys {
                state.knownCategories.insert("\(type.rawValue)|\(apiId)")
            }
            state.categoryOrder[type.rawValue] = lookup.count
        }

        var headerEPGURL: String?
        try M3UParser.parse(fileURL: fileURL, batchSize: 2000) { header in
            headerEPGURL = header.epgURL
        } onBatch: { batch in
            guard state.firstError == nil else { return }
            do {
                try autoreleasepool {
                    try self.importBatch(batch, playlistId: playlistId, state: state)
                }
                let imported = state.totalImported
                Logger.database.info("m3u import: \(imported) items so far")
                Task { await progress?.update(detail: "\(imported) items") }
            } catch {
                state.firstError = error
            }
        }

        if let error = state.firstError {
            throw SyncError.databaseError(error)
        }

        // Sweep rows the file no longer carries. Gate on a non-empty import:
        // total == 0 means the download/parse produced nothing (failure or empty
        // file), where sweeping would wipe the catalog. Once the file is known
        // good, a per-kind zero is legitimate — a live-only playlist correctly
        // prunes any movies/series left from when it carried them.
        if state.totalImported > 0 {
            pruneStaleLiveStreams(playlistId: playlistId, seenIds: state.seenLiveIds)
            pruneStaleMovies(playlistId: playlistId, seenIds: state.seenMovieIds)
            pruneStaleEpisodes(playlistId: playlistId, seenIds: state.seenEpisodeIds)
            pruneStaleSeries(playlistId: playlistId, seenIds: state.seenSeriesIds)
            for type in CategoryType.allCases {
                let typePrefix = "\(type.rawValue)|"
                let seenApiIds = Set(
                    state.seenCategoryKeys
                        .filter { $0.hasPrefix(typePrefix) }
                        .map { String($0.dropFirst(typePrefix.count)) }
                )
                pruneStaleCategories(playlistId: playlistId, type: type, seenApiIds: seenApiIds)
            }
        }

        return M3UImportSummary(
            liveCount: state.importedLive,
            movieCount: state.importedMovies,
            episodeCount: state.importedEpisodes,
            headerEPGURL: headerEPGURL
        )
    }

    // MARK: - Batch import

    /// One batch of entries split by classification.
    private struct ClassifiedBatch {
        var live: [M3UEntry] = []
        var movies: [M3UEntry] = []
        var episodes: [(M3UEntry, series: String, season: Int, episode: Int)] = []
    }

    private func importBatch(_ entries: [M3UEntry], playlistId: UUID, state: M3UImportState) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        var batch = ClassifiedBatch()
        for entry in entries {
            switch M3UClassifier.classify(entry) {
            case .live: batch.live.append(entry)
            case .movie: batch.movies.append(entry)
            case let .episode(series, season, episode):
                batch.episodes.append((entry, series, season, episode))
            }
        }

        try ensureCategories(for: batch, playlistId: playlistId, state: state, context: context)
        importLive(batch.live, playlistId: playlistId, state: state, context: context)
        importMovies(batch.movies, playlistId: playlistId, state: state, context: context)
        importEpisodes(batch.episodes, playlistId: playlistId, state: state, context: context)

        try context.save()
    }

    /// Creates any categories this batch references for the first time.
    /// Group titles double as the category's `apiId` — m3u has no numeric ids.
    private func ensureCategories(
        for batch: ClassifiedBatch,
        playlistId: UUID,
        state: M3UImportState,
        context: ModelContext
    ) throws {
        var needed: [(type: CategoryType, group: String)] = []
        func collect(_ group: String?, type: CategoryType) {
            let name = (group?.isEmpty == false) ? group! : Self.uncategorizedGroup
            let key = "\(type.rawValue)|\(name)"
            // Record every category referenced this sync — including ones that
            // already exist — so the post-import sweep keeps them.
            state.seenCategoryKeys.insert(key)
            guard !state.knownCategories.contains(key) else { return }
            state.knownCategories.insert(key)
            needed.append((type, name))
        }
        for entry in batch.live {
            collect(entry.group, type: .live)
        }
        for entry in batch.movies {
            collect(entry.group, type: .vod)
        }
        for (entry, _, _, _) in batch.episodes {
            collect(entry.group, type: .series)
        }

        guard !needed.isEmpty else { return }
        guard let playlist = try context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { throw SyncError.playlistNotFound }

        for (type, group) in needed {
            let category = Category(apiId: group, name: group, parentId: 0, type: type, playlist: playlist)
            var order = state.categoryOrder[type.rawValue, default: 0]
            category.sortOrder = order
            order += 1
            state.categoryOrder[type.rawValue] = order
            category.lastRefreshed = Date()
            context.insert(category)
        }
    }

    private func categoryId(for group: String?, type: CategoryType, playlistId: UUID) -> String {
        let name = (group?.isEmpty == false) ? group! : Self.uncategorizedGroup
        return "\(playlistId.uuidString)-\(type.rawValue)-\(name)"
    }

    private func importLive(_ entries: [M3UEntry], playlistId: UUID, state: M3UImportState, context: ModelContext) {
        guard !entries.isEmpty else { return }
        let ids = entries.map { "\(playlistId.uuidString)-live-\(M3UIdentity.key(for: $0.url))" }
        state.seenLiveIds.formUnion(ids)
        var existing: [String: LiveStream] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<LiveStream>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for stream in fetched {
            existing[stream.id] = stream
        }

        for (entry, id) in zip(entries, ids) {
            let stream: LiveStream
            if let found = existing[id] {
                stream = found
            } else {
                stream = LiveStream(id: id, streamId: M3UIdentity.numericId(for: entry.url), name: "")
                context.insert(stream)
                existing[id] = stream
            }
            stream.name = entry.name
            stream.streamIcon = entry.logo
            stream.epgChannelId = entry.tvgId
            stream.directURL = entry.url
            stream.num = state.liveNum
            stream.categoryId = categoryId(for: entry.group, type: .live, playlistId: playlistId)
            state.liveNum += 1
        }
        state.importedLive += entries.count
    }

    private func importMovies(_ entries: [M3UEntry], playlistId: UUID, state: M3UImportState, context: ModelContext) {
        guard !entries.isEmpty else { return }
        let ids = entries.map { "\(playlistId.uuidString)-movie-\(M3UIdentity.key(for: $0.url))" }
        state.seenMovieIds.formUnion(ids)
        var existing: [String: Movie] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for movie in fetched {
            existing[movie.id] = movie
        }

        for (entry, id) in zip(entries, ids) {
            let movie: Movie
            if let found = existing[id] {
                movie = found
            } else {
                movie = Movie(id: id, streamId: M3UIdentity.numericId(for: entry.url), name: "")
                context.insert(movie)
                existing[id] = movie
            }
            movie.name = entry.name
            movie.streamIcon = entry.logo
            movie.directURL = entry.url
            movie.containerExtension = M3UClassifier.pathExtension(of: entry.url)
            movie.num = state.movieNum
            movie.categoryId = categoryId(for: entry.group, type: .vod, playlistId: playlistId)
            state.movieNum += 1
        }
        state.importedMovies += entries.count
    }

    private func importEpisodes(
        _ entries: [(M3UEntry, series: String, season: Int, episode: Int)],
        playlistId: UUID,
        state: M3UImportState,
        context: ModelContext
    ) {
        guard !entries.isEmpty else { return }

        let seriesIds = entries.map { "\(playlistId.uuidString)-series-\(M3UIdentity.key(for: $0.series))" }
        let episodeIds = entries.enumerated().map { index, entry in
            "\(seriesIds[index])-episode-\(M3UIdentity.key(for: entry.0.url))"
        }
        state.seenSeriesIds.formUnion(seriesIds)
        state.seenEpisodeIds.formUnion(episodeIds)
        var seriesById = existingSeries(ids: seriesIds, context: context)
        var existingEpisodes = existingEpisodes(ids: episodeIds, context: context)

        for (index, item) in entries.enumerated() {
            let (entry, seriesName, season, episodeNum) = item
            let seriesId = seriesIds[index]

            let series: Series
            if let found = seriesById[seriesId] {
                series = found
            } else {
                series = Series(id: seriesId, seriesId: M3UIdentity.numericId(for: seriesName), name: seriesName)
                series.num = state.seriesNum
                state.seriesNum += 1
                context.insert(series)
                seriesById[seriesId] = series
            }
            series.categoryId = categoryId(for: entry.group, type: .series, playlistId: playlistId)
            if series.cover == nil {
                series.cover = entry.logo
            }

            let episodeId = episodeIds[index]
            let episode: Episode
            if let found = existingEpisodes[episodeId] {
                episode = found
            } else {
                episode = Episode(
                    id: episodeId,
                    episodeId: M3UIdentity.key(for: entry.url),
                    title: "",
                    containerExtension: M3UClassifier.pathExtension(of: entry.url) ?? "mp4",
                    seasonNum: season,
                    episodeNum: episodeNum,
                    series: series
                )
                context.insert(episode)
                existingEpisodes[episodeId] = episode
            }
            episode.title = Self.cleanEpisodeTitle(entry.name)
            episode.directSource = entry.url
            episode.movieImage = entry.logo
            state.importedEpisodes += 1
        }
    }

    private func existingSeries(ids: [String], context: ModelContext) -> [String: Series] {
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

    private func existingEpisodes(ids: [String], context: ModelContext) -> [String: Episode] {
        var lookup: [String: Episode] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<Episode>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for episode in fetched {
            lookup[episode.id] = episode
        }
        return lookup
    }

    // MARK: - Playlist bookkeeping

    private func persistDiscoveredEPGURL(_ url: String, playlistId: UUID) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }
        playlist.epgURL = url
        EPGSourceReconciler.reconcile(playlist, in: context)
        try? context.save()
        Logger.database.info("Adopted EPG URL from playlist url-tvg header")
    }

    private func markPlaylistUpdated(_ playlistId: UUID) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }
        playlist.lastUpdated = Date()
        try? context.save()
    }
}

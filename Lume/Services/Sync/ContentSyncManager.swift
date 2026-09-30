//
//  ContentSyncManager.swift
//  Lume
//
//  Manages content synchronization from Xtream API to SwiftData
//

import Foundation
import OSLog
import SwiftData

// MARK: - ContentSyncManager

actor ContentSyncManager {
    // MARK: - Properties

    let modelContainer: ModelContainer
    let xtreamClient: XtreamClient
    let webdavClient: WebDAVClient
    let jellyfinClient: JellyfinClient
    let plexClient: PlexClient
    private var activeSyncPlaylistIDs: Set<UUID> = []

    /// Number of items to process before saving and resetting the context.
    let batchSize = 2000

    // MARK: - Initialization

    init(
        modelContainer: ModelContainer,
        xtreamClient: XtreamClient = XtreamClient(),
        webdavClient: WebDAVClient = WebDAVClient(),
        jellyfinClient: JellyfinClient = JellyfinClient(),
        plexClient: PlexClient = PlexClient()
    ) {
        self.modelContainer = modelContainer
        self.xtreamClient = xtreamClient
        self.webdavClient = webdavClient
        self.jellyfinClient = jellyfinClient
        self.plexClient = plexClient
    }

    // MARK: - Playlist Sync

    /// Performs a full sync of a playlist (categories and content)
    func syncPlaylist(_ playlist: Playlist, progress: SyncProgress? = nil, full: Bool = false) async throws {
        let playlistId = playlist.id

        guard !activeSyncPlaylistIDs.contains(playlistId) else {
            throw SyncError.syncInProgress
        }

        activeSyncPlaylistIDs.insert(playlistId)
        defer { activeSyncPlaylistIDs.remove(playlistId) }

        do {
            // Run directly in the caller's task — no wrapping unstructured Task —
            // so cancelling the caller (e.g. the user aborting from the progress
            // sheet) propagates here and tears the sync down.
            try await performSync(playlistId: playlistId, progress: progress, full: full)
        } catch {
            // An aborted sync isn't a failure: restore the playlist to idle so it
            // can be retried cleanly, rather than wedging it in the error state.
            if Task.isCancelled {
                Logger.database.info("Sync cancelled for playlist \(playlistId)")
                markPlaylistIdle(playlistId: playlistId)
            } else {
                Logger.database.error("Sync failed for playlist \(playlistId) — \(error)")
                markPlaylistError(playlistId: playlistId)
            }
            throw error
        }

        Logger.database.info("Completed sync for playlist \(playlistId)")

        // Nudge iCloud sync: a freshly fetched catalog may now be able to apply
        // cloud user state (favorites / progress) that was waiting for it.
        NotificationCenter.default.post(name: .lumeContentSyncDidComplete, object: nil)
    }

    private func performSync(playlistId: UUID, progress: SyncProgress?, full: Bool) async throws {
        // Whole-sync interval: the umbrella every phase below nests under, so a
        // trace (or `XCTOSSignpostMetric`) shows both the total and the split.
        let interval = Perf.begin(.playlistSync)
        defer { Perf.end(interval) }

        let statusContext = ModelContext(modelContainer)
        statusContext.autosaveEnabled = false
        guard let playlist = try statusContext.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else {
            Logger.database.error("Sync aborted: playlist \(playlistId) not found in store")
            throw SyncError.playlistNotFound
        }

        playlist.syncStatus = .syncing
        try statusContext.save()

        switch playlist.sourceType {
        case .xtream:
            try await performXtreamSync(playlist: playlist, playlistId: playlistId, progress: progress, full: full)
        case .m3u:
            try await performM3USync(playlist: playlist, playlistId: playlistId, progress: progress)
        case .stalker:
            try await performStalkerSync(playlist: playlist, playlistId: playlistId, progress: progress, full: full)
        case .webdav:
            try await performWebDAVSync(playlist: playlist, playlistId: playlistId, progress: progress)
        case .jellyfin, .emby:
            // Both speak the same API; the flavour only tags the rows.
            let flavor = MediaServerFlavor(sourceType: playlist.sourceType) ?? .jellyfin
            try await performMediaServerSync(playlist: playlist, playlistId: playlistId, flavor: flavor, progress: progress)
        case .plex:
            try await performPlexSync(playlist: playlist, playlistId: playlistId, progress: progress)
        }

        // Every source writes the same unread history rows (see the method).
        purgeCatalogHistory()

        let doneContext = ModelContext(modelContainer)
        doneContext.autosaveEnabled = false
        if let dpl = try doneContext.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first {
            dpl.syncStatus = .idle
            dpl.lastSyncDate = Date()
            try doneContext.save()
        }
    }

    /// The Xtream pipeline: authenticate, then pull categories and content
    /// through the provider's JSON API.
    private func performXtreamSync(playlist: Playlist, playlistId: UUID, progress: SyncProgress?, full: Bool) async throws {
        await progress?.start(.authenticating)
        let authResponse = try await xtreamClient.getInfo(playlist: playlist)
        updatePlaylistInfo(playlistId, with: authResponse)
        await progress?.complete(.authenticating)

        try await syncAllCategories(for: playlist, playlistId: playlistId, progress: progress, full: full)

        // Serialized and spaced apart on purpose — see
        // `spaceContentPhaseRequests` for the connection-cap reason.
        // A manual full sync re-imports every phase; a scheduled one skips a
        // phase whose payload is byte-identical to its last import.
        let reuse = !full
        try await syncMovies(for: playlist, playlistId: playlistId, progress: progress, reuseUnchanged: reuse)
        try await spaceContentPhaseRequests()
        try await syncSeries(for: playlist, playlistId: playlistId, progress: progress, reuseUnchanged: reuse)
        try await spaceContentPhaseRequests()
        try await syncLiveStreams(for: playlist, playlistId: playlistId, progress: progress, reuseUnchanged: reuse)
    }

    func syncAllCategories(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil, full _: Bool = false) async throws {
        Logger.database.info("Starting VOD category sync")
        await progress?.start(.movieCategories)
        try await syncVODCategories(for: playlist, playlistId: playlistId, progress: progress)
        await progress?.complete(.movieCategories)

        Logger.database.info("Starting Series category sync")
        await progress?.start(.seriesCategories)
        try await syncSeriesCategories(for: playlist, playlistId: playlistId, progress: progress)
        await progress?.complete(.seriesCategories)

        Logger.database.info("Starting Live TV category sync")
        await progress?.start(.liveCategories)
        try await syncLiveCategories(for: playlist, playlistId: playlistId, progress: progress)
        await progress?.complete(.liveCategories)
    }

    // MARK: - Category Sync

    private func syncVODCategories(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil) async throws {
        let categories = try await xtreamClient.getVODCategories(playlist: playlist)
        Logger.database.info("Fetched \(categories.count) VOD categories")
        await progress?.update(detail: "\(categories.count) categories")
        try syncCategories(categories, type: .vod, playlistId: playlistId)
    }

    private func syncSeriesCategories(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil) async throws {
        let categories = try await xtreamClient.getSeriesCategories(playlist: playlist)
        Logger.database.info("Fetched \(categories.count) Series categories")
        await progress?.update(detail: "\(categories.count) categories")
        try syncCategories(categories, type: .series, playlistId: playlistId)
    }

    private func syncLiveCategories(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil) async throws {
        let categories = try await xtreamClient.getLiveCategories(playlist: playlist)
        Logger.database.info("Fetched \(categories.count) Live categories")
        await progress?.update(detail: "\(categories.count) categories")
        try syncCategories(categories, type: .live, playlistId: playlistId)
    }

    private func syncCategories(_ dtos: [XtreamCategory], type: CategoryType, playlistId: UUID) throws {
        let interval = Perf.begin(.syncCategories)
        defer { Perf.end(interval) }

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let categoryLookup = buildExistingCategoryLookup(context: context, playlistId: playlistId, type: type)

        guard let playlist = try context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        for (index, categoryDTO) in dtos.enumerated() {
            if let existingCat = categoryLookup[categoryDTO.categoryId] {
                // Written only when changed, so an unchanged sync saves nothing.
                // `lastRefreshed` is stamped on insert only: nothing reads it.
                if existingCat.name != categoryDTO.categoryName { existingCat.name = categoryDTO.categoryName }
                let parentId = categoryDTO.parentId ?? 0
                if existingCat.parentId != parentId { existingCat.parentId = parentId }
                if existingCat.sortOrder != index { existingCat.sortOrder = index }
            } else {
                let category = Category(
                    apiId: categoryDTO.categoryId,
                    name: categoryDTO.categoryName,
                    parentId: categoryDTO.parentId ?? 0,
                    type: type,
                    playlist: playlist
                )
                category.sortOrder = index
                category.lastRefreshed = Date()
                context.insert(category)
            }
        }

        if context.hasChanges { try context.save() }

        // Remove categories of this type the provider has dropped. Gated on a
        // non-empty fetch: an empty category list is the transient-failure
        // signature, and sweeping then would drop every category for the type.
        if !dtos.isEmpty {
            let seenApiIds = Set(dtos.map(\.categoryId))
            pruneStaleCategories(playlistId: playlistId, type: type, seenApiIds: seenApiIds)
        }
    }

    /// Syncs episodes for a series
    /// Fetches and parses a series' episodes from the provider **without**
    /// touching the database.
    ///
    /// The caller inserts the returned episodes through its own (view) context,
    /// attaching them to the `Series` instance it already holds. Writing through
    /// a separate background context instead leaves the view-context series'
    /// `episodes` relationship stale until a later cross-context merge — which
    /// races the UI refresh and, on tvOS, loses (episodes only appear after
    /// navigating away and back). Returning value types sidesteps that entirely.
    func fetchEpisodes(seriesId: Int, seriesElementId: String, playlist: Playlist) async throws -> [ParsedEpisode] {
        switch playlist.sourceType {
        case .xtream:
            try await fetchXtreamEpisodes(seriesId: seriesId, seriesElementId: seriesElementId, playlist: playlist)
        case .stalker:
            try await fetchStalkerEpisodes(seriesId: seriesId, seriesElementId: seriesElementId, playlist: playlist)
        case .m3u:
            // m3u episodes are imported alongside the rest of the catalog during
            // sync, so there is nothing to fetch lazily here.
            []
        case .webdav:
            // WebDAV episodes are imported alongside the rest of the catalog
            // during sync, so there is nothing to fetch lazily here.
            []
        case .jellyfin, .emby, .plex:
            // Media-server episodes are imported alongside the rest of the
            // catalog during sync, so there is nothing to fetch lazily here.
            []
        }
    }

    private func fetchXtreamEpisodes(seriesId: Int, seriesElementId: String, playlist: Playlist) async throws -> [ParsedEpisode] {
        let seriesInfo = try await xtreamClient.getSeriesInfo(playlist: playlist, seriesId: seriesId)
        guard let episodesDict = seriesInfo.episodes else { return [] }

        var result: [ParsedEpisode] = []
        for (seasonKey, episodes) in episodesDict {
            guard let seasonNum = Int(seasonKey) else { continue }
            for episodeDTO in episodes {
                guard let episodeIdString = episodeDTO.id else { continue }
                let plot = episodeDTO.info?.plot
                result.append(ParsedEpisode(
                    id: "\(seriesElementId)-episode-\(episodeIdString)",
                    episodeId: episodeIdString,
                    title: Self.cleanEpisodeTitle(episodeDTO.title),
                    containerExtension: episodeDTO.containerExtension ?? "mkv",
                    seasonNum: seasonNum,
                    episodeNum: episodeDTO.episodeNum ?? 0,
                    added: episodeDTO.added,
                    directSource: episodeDTO.directSource,
                    durationSecs: episodeDTO.info?.durationSecs,
                    movieImage: episodeDTO.info?.movieImage,
                    rating: episodeDTO.info?.rating,
                    airDate: episodeDTO.info?.airDate,
                    plot: (plot?.isEmpty == false) ? plot : nil
                ))
            }
        }
        return result
    }

    /// Reduces a raw Xtream episode title to just the episode name.
    ///
    /// Providers commonly prefix the series and a season/episode token, e.g.
    /// "Breaking Bad - S05E16 - Felina" or "Breaking Bad S05E16 Felina". We locate
    /// the first `SxxExx` / `NxM` token and keep whatever follows it ("Felina").
    /// Titles with no such token are returned untouched; a token with nothing after
    /// it (e.g. "Breaking Bad - S05E16") yields "" so the UI can fall back to "E16".
    static func cleanEpisodeTitle(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ""
        }

        let token = #"(?i)\bS\d{1,3}\s*E\d{1,4}\b|\b\d{1,3}x\d{1,4}\b"#
        guard let match = raw.range(of: token, options: .regularExpression) else {
            return raw
        }

        let separators = CharacterSet(charactersIn: " -–—·:|.").union(.whitespacesAndNewlines)
        return raw[match.upperBound...].trimmingCharacters(in: separators)
    }
}

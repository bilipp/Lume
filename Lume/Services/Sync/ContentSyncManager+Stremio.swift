//
//  ContentSyncManager+Stremio.swift
//  Lume
//
//  The Stremio addon sync pipeline. Loads the addon's manifest, then maps its
//  browsable catalogs onto the same SwiftData models the Xtream, m3u and
//  Stalker pipelines fill — movie catalogs become Movie rows, series catalogs
//  Series rows, and tv/channel catalogs LiveStream rows — so browsing, search,
//  favorites and enrichment all work identically across source types.
//
//  Stream URLs are not part of the catalog: each item stores a
//  `lumestremio://` placeholder (in `directURL` / `directSource`) carrying its
//  Stremio type and id, and the real URL is resolved at playback time via
//  `/stream/{type}/{id}.json` (see `StremioStreamResolver`).
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    /// How many items to pull per catalog. Stremio catalogs page in steps of
    /// 100 and can be effectively endless (Cinemeta's "Popular" walks the whole
    /// of IMDb), so sync takes the top pages rather than draining them.
    private static let maxItemsPerCatalog = 500

    /// The protocol's fixed catalog page size; a shorter page ends the walk.
    private static let catalogPageSize = 100

    /// A positive `Int` stream id for a Stremio meta id. Stremio ids are
    /// strings (`"tt1254207"`, `"kitsu:1234"`), so they're hashed the same way
    /// m3u identities are — deterministic across re-syncs.
    private static func streamId(for stremioId: String) -> Int {
        M3UIdentity.numericId(for: stremioId)
    }

    /// A category `apiId` unique across an addon's catalogs. Includes the
    /// Stremio type because both `tv` and `channel` map onto `.live`, and
    /// addons reuse catalog ids (Cinemeta calls every default catalog `top`).
    private static func categoryApiId(for catalog: StremioCatalog) -> String {
        "\(catalog.type)/\(catalog.id)"
    }

    /// The Stremio pipeline: load the manifest, then walk each browsable
    /// catalog. Catalogs requiring an extra (search-only, mandatory genre) are
    /// skipped — they can't be browsed plainly.
    func performStremioSync(playlist: Playlist, playlistId: UUID, progress: SyncProgress?, full _: Bool = false) async throws {
        let client = StremioClient(configuration: StremioClient.Configuration(playlist: playlist))

        await progress?.start(.authenticating)
        let manifest = try await client.getManifest()
        updateStremioPlaylistInfo(playlistId, manifest: manifest)
        await progress?.complete(.authenticating)

        let browsable = manifest.catalogs.filter(\.isBrowsable)
        let movieCatalogs = browsable.filter { $0.type == "movie" }
        let seriesCatalogs = browsable.filter { $0.type == "series" }
        let liveCatalogs = browsable.filter { $0.type == "tv" || $0.type == "channel" }

        await progress?.start(.movieCategories)
        try syncStremioCategories(movieCatalogs, type: .vod, playlistId: playlistId)
        await progress?.update(detail: "\(movieCatalogs.count) categories")
        await progress?.complete(.movieCategories)

        await progress?.start(.seriesCategories)
        try syncStremioCategories(seriesCatalogs, type: .series, playlistId: playlistId)
        await progress?.update(detail: "\(seriesCatalogs.count) categories")
        await progress?.complete(.seriesCategories)

        await progress?.start(.liveCategories)
        try syncStremioCategories(liveCatalogs, type: .live, playlistId: playlistId)
        await progress?.update(detail: "\(liveCatalogs.count) categories")
        await progress?.complete(.liveCategories)

        try await syncStremioMovies(client: client, catalogs: movieCatalogs, playlistId: playlistId, progress: progress)
        try await syncStremioSeries(client: client, catalogs: seriesCatalogs, playlistId: playlistId, progress: progress)
        try await syncStremioLive(client: client, catalogs: liveCatalogs, playlistId: playlistId, progress: progress)

        markStremioPlaylistUpdated(playlistId)
    }

    /// Walks a catalog's pages until it ends or the per-catalog cap is hit.
    /// A failing page is treated as the end of the catalog rather than a sync
    /// failure — per the protocol, an erroring addon just has no (more) results.
    private func fetchCatalogItems(client: StremioClient, catalog: StremioCatalog) async throws -> [StremioMeta] {
        var all: [StremioMeta] = []
        var skip = 0
        while all.count < Self.maxItemsPerCatalog {
            try Task.checkCancellation()
            guard let page = try? await client.getCatalog(type: catalog.type, id: catalog.id, skip: skip).metas,
                  !page.isEmpty
            else { break }
            all.append(contentsOf: page)
            if page.count < Self.catalogPageSize || !catalog.supportsSkip { break }
            skip += page.count
        }
        return Array(all.prefix(Self.maxItemsPerCatalog))
    }

    // MARK: - Categories

    private func syncStremioCategories(_ catalogs: [StremioCatalog], type: CategoryType, playlistId: UUID) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let lookup = buildExistingCategoryLookup(context: context, playlistId: playlistId, type: type)
        guard let playlist = try context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        for (index, catalog) in catalogs.enumerated() {
            let apiId = Self.categoryApiId(for: catalog)
            let name = catalog.name ?? catalog.id.capitalized
            if let existing = lookup[apiId] {
                existing.name = name
                existing.sortOrder = index
                existing.lastRefreshed = Date()
            } else {
                let category = Category(apiId: apiId, name: name, parentId: 0, type: type, playlist: playlist)
                category.sortOrder = index
                category.lastRefreshed = Date()
                context.insert(category)
            }
        }
        try context.save()

        if !catalogs.isEmpty {
            pruneStaleCategories(
                playlistId: playlistId, type: type,
                seenApiIds: Set(catalogs.map { Self.categoryApiId(for: $0) })
            )
        }
    }

    // MARK: - Movies

    private func syncStremioMovies(
        client: StremioClient,
        catalogs: [StremioCatalog],
        playlistId: UUID,
        progress: SyncProgress?
    ) async throws {
        await progress?.start(.movies)
        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.vod.rawValue)-"
        var seenIds = Set<String>()
        var imported = 0

        for catalog in catalogs {
            let metas = try await fetchCatalogItems(client: client, catalog: catalog)
            guard !metas.isEmpty else { continue }
            let categoryId = playlistPrefix + Self.categoryApiId(for: catalog)
            autoreleasepool {
                imported += upsertStremioMovies(metas, categoryId: categoryId, playlistId: playlistId, seenIds: &seenIds)
            }
            await progress?.update(detail: "\(imported) items")
        }

        if !seenIds.isEmpty {
            pruneStaleMovies(playlistId: playlistId, seenIds: seenIds)
        }
        Logger.database.info("Stremio: synced \(imported) movies")
        await progress?.complete(.movies)
    }

    /// Upserts one catalog's movie metas on a fresh context and returns how
    /// many were imported.
    private func upsertStremioMovies(
        _ metas: [StremioMeta],
        categoryId: String,
        playlistId: UUID,
        seenIds: inout Set<String>
    ) -> Int {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = metas.map { "\(playlistId.uuidString)-movie-\(Self.streamId(for: $0.id))" }
        var existing: [String: Movie] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for movie in fetched {
            existing[movie.id] = movie
        }

        var imported = 0
        for meta in metas {
            let streamId = Self.streamId(for: meta.id)
            let movieId = "\(playlistId.uuidString)-movie-\(streamId)"
            // An item can appear in several catalogs; the first one wins so it
            // isn't re-assigned (and re-counted) per catalog.
            guard seenIds.insert(movieId).inserted else { continue }

            let movie: Movie
            if let found = existing[movieId] {
                movie = found
            } else {
                movie = Movie(id: movieId, streamId: streamId, name: "")
                context.insert(movie)
            }
            movie.name = meta.name ?? meta.id
            movie.streamIcon = meta.poster
            movie.plot = meta.metaDescription
            movie.releaseDate = meta.releaseInfo
            movie.rating = Double(meta.imdbRating ?? "") ?? movie.rating
            movie.genre = meta.genres?.joined(separator: ", ")
            if meta.id.hasPrefix("tt") {
                movie.imdbId = meta.id
            }
            movie.categoryId = categoryId
            movie.directURL = StremioLink.placeholder(type: meta.type.isEmpty ? "movie" : meta.type, id: meta.streamRequestId)?.absoluteString
            imported += 1
        }
        try? context.save()
        return imported
    }

    // MARK: - Series

    private func syncStremioSeries(
        client: StremioClient,
        catalogs: [StremioCatalog],
        playlistId: UUID,
        progress: SyncProgress?
    ) async throws {
        await progress?.start(.series)
        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.series.rawValue)-"
        var seenIds = Set<String>()
        var imported = 0

        for catalog in catalogs {
            let metas = try await fetchCatalogItems(client: client, catalog: catalog)
            guard !metas.isEmpty else { continue }
            let categoryId = playlistPrefix + Self.categoryApiId(for: catalog)
            autoreleasepool {
                imported += upsertStremioSeries(metas, categoryId: categoryId, playlistId: playlistId, seenIds: &seenIds)
            }
            await progress?.update(detail: "\(imported) items")
        }

        if !seenIds.isEmpty {
            pruneStaleSeries(playlistId: playlistId, seenIds: seenIds)
        }
        Logger.database.info("Stremio: synced \(imported) series")
        await progress?.complete(.series)
    }

    /// Upserts one catalog's series metas on a fresh context and returns how
    /// many were imported. Episodes are fetched lazily on the detail screen
    /// (see `fetchStremioEpisodes`) — pulling full metas for every series here
    /// would mean one request per title.
    private func upsertStremioSeries(
        _ metas: [StremioMeta],
        categoryId: String,
        playlistId: UUID,
        seenIds: inout Set<String>
    ) -> Int {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = metas.map { "\(playlistId.uuidString)-series-\(Self.streamId(for: $0.id))" }
        var existing: [String: Series] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for series in fetched {
            existing[series.id] = series
        }

        var imported = 0
        for meta in metas {
            let seriesId = Self.streamId(for: meta.id)
            let id = "\(playlistId.uuidString)-series-\(seriesId)"
            guard seenIds.insert(id).inserted else { continue }

            let series: Series
            if let found = existing[id] {
                series = found
            } else {
                series = Series(id: id, seriesId: seriesId, name: "")
                context.insert(series)
            }
            series.name = meta.name ?? meta.id
            series.cover = meta.poster
            series.plot = meta.metaDescription
            series.releaseDate = meta.releaseInfo
            series.rating = meta.imdbRating
            series.genre = meta.genres?.joined(separator: ", ")
            if meta.id.hasPrefix("tt") {
                series.imdbId = meta.id
            }
            series.stremioId = meta.id
            series.categoryId = categoryId
            imported += 1
        }
        try? context.save()
        return imported
    }

    /// Fetches a Stremio series' episodes on demand (the series detail screen
    /// calls this through `fetchEpisodes`). The series' full meta carries the
    /// episode list; each episode stores a placeholder link resolved at
    /// playback time. Episodes that haven't aired yet are skipped — they have
    /// no streams to resolve.
    func fetchStremioEpisodes(seriesElementId: String, playlist: Playlist) async throws -> [ParsedEpisode] {
        let context = ModelContext(modelContainer)
        guard let stremioId = try context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == seriesElementId })
        ).first?.stremioId else { return [] }

        let client = StremioClient(configuration: StremioClient.Configuration(playlist: playlist))
        let meta = try await client.getMeta(type: "series", id: stremioId).meta

        let now = Date()
        // Addons send `released` with and without fractional seconds; ISO8601
        // parsing is strict about the difference, so try both.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        var result: [ParsedEpisode] = []
        for (index, video) in (meta.videos ?? []).enumerated() {
            if let released = video.released,
               let releaseDate = fractional.date(from: released) ?? plain.date(from: released),
               releaseDate > now
            { continue }
            guard let placeholder = StremioLink.placeholder(type: "series", id: video.id) else { continue }
            result.append(ParsedEpisode(
                id: "\(seriesElementId)-episode-\(video.id)",
                episodeId: video.id,
                title: video.title ?? "",
                containerExtension: "mp4",
                seasonNum: video.season ?? 1,
                episodeNum: video.episode ?? index + 1,
                added: nil,
                directSource: placeholder.absoluteString,
                durationSecs: nil,
                movieImage: video.thumbnail,
                rating: nil,
                airDate: video.released,
                plot: video.overview
            ))
        }
        return result
    }

    // MARK: - Live channels (tv / channel)

    private func syncStremioLive(
        client: StremioClient,
        catalogs: [StremioCatalog],
        playlistId: UUID,
        progress: SyncProgress?
    ) async throws {
        await progress?.start(.liveStreams)
        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.live.rawValue)-"
        var seenIds = Set<String>()
        var imported = 0

        for catalog in catalogs {
            let metas = try await fetchCatalogItems(client: client, catalog: catalog)
            guard !metas.isEmpty else { continue }
            let categoryId = playlistPrefix + Self.categoryApiId(for: catalog)
            autoreleasepool {
                imported += upsertStremioChannels(metas, categoryId: categoryId, playlistId: playlistId, seenIds: &seenIds)
            }
            await progress?.update(detail: "\(imported) items")
        }

        if !seenIds.isEmpty {
            pruneStaleLiveStreams(playlistId: playlistId, seenIds: seenIds)
        }
        Logger.database.info("Stremio: synced \(imported) live channels")
        await progress?.complete(.liveStreams)
    }

    /// Upserts one catalog's channel metas on a fresh context and returns how
    /// many were imported.
    private func upsertStremioChannels(
        _ metas: [StremioMeta],
        categoryId: String,
        playlistId: UUID,
        seenIds: inout Set<String>
    ) -> Int {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = metas.map { "\(playlistId.uuidString)-live-\(Self.streamId(for: $0.id))" }
        var existing: [String: LiveStream] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<LiveStream>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for stream in fetched {
            existing[stream.id] = stream
        }

        var imported = 0
        for (index, meta) in metas.enumerated() {
            let streamId = Self.streamId(for: meta.id)
            let id = "\(playlistId.uuidString)-live-\(streamId)"
            guard seenIds.insert(id).inserted else { continue }

            let stream: LiveStream
            if let found = existing[id] {
                stream = found
            } else {
                stream = LiveStream(id: id, streamId: streamId, name: "")
                context.insert(stream)
            }
            stream.name = meta.name ?? meta.id
            stream.streamIcon = meta.logo ?? meta.poster
            stream.num = index + 1
            stream.categoryId = categoryId
            stream.directURL = StremioLink.placeholder(type: meta.type.isEmpty ? "tv" : meta.type, id: meta.streamRequestId)?.absoluteString
            imported += 1
        }
        try? context.save()
        return imported
    }

    // MARK: - Playlist bookkeeping

    private func updateStremioPlaylistInfo(_ playlistId: UUID, manifest: StremioManifest) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }
        playlist.serverVersion = manifest.version
        playlist.lastUpdated = Date()
        try? context.save()
    }

    private func markStremioPlaylistUpdated(_ playlistId: UUID) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }
        playlist.lastUpdated = Date()
        try? context.save()
    }
}

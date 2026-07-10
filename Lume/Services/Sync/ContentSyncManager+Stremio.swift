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
//  Stream-capable addons additionally get Cinemeta's Popular/Featured
//  catalogs attached (see `cinemetaCompanionSources`), mirroring the Stremio
//  app where Cinemeta is pre-installed and fills Discover.
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
    /// How many items to pull per catalog. Stremio catalogs can be effectively
    /// endless (Cinemeta's "Popular" walks the whole of IMDb), so sync takes
    /// the top pages rather than draining them.
    private static let maxItemsPerCatalog = 500

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

    /// One catalog to sync, paired with the client that serves it — the
    /// playlist's own addon, or the Cinemeta companion. `categoryApiId` is
    /// prefixed for companion catalogs so they can't collide with an addon
    /// catalog of the same type/id.
    nonisolated struct StremioCatalogSource {
        let client: StremioClient
        let catalog: StremioCatalog
        let categoryApiId: String
    }

    private static func catalogSources(
        client: StremioClient,
        catalogs: [StremioCatalog],
        apiIdPrefix: String = ""
    ) -> [StremioCatalogSource] {
        catalogs.map {
            StremioCatalogSource(client: client, catalog: $0, categoryApiId: apiIdPrefix + categoryApiId(for: $0))
        }
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
        var movieSources = Self.catalogSources(client: client, catalogs: browsable.filter { $0.type == "movie" })
        var seriesSources = Self.catalogSources(client: client, catalogs: browsable.filter { $0.type == "series" })
        let liveSources = Self.catalogSources(client: client, catalogs: browsable.filter { $0.type == "tv" || $0.type == "channel" })

        let companion = await cinemetaCompanionSources(for: manifest)
        movieSources += companion.movies
        seriesSources += companion.series

        await progress?.start(.movieCategories)
        try syncStremioCategories(movieSources, type: .vod, playlistId: playlistId)
        await progress?.update(detail: "\(movieSources.count) categories")
        await progress?.complete(.movieCategories)

        await progress?.start(.seriesCategories)
        try syncStremioCategories(seriesSources, type: .series, playlistId: playlistId)
        await progress?.update(detail: "\(seriesSources.count) categories")
        await progress?.complete(.seriesCategories)

        await progress?.start(.liveCategories)
        try syncStremioCategories(liveSources, type: .live, playlistId: playlistId)
        await progress?.update(detail: "\(liveSources.count) categories")
        await progress?.complete(.liveCategories)

        try await syncStremioMovies(sources: movieSources, playlistId: playlistId, progress: progress)
        try await syncStremioSeries(sources: seriesSources, playlistId: playlistId, progress: progress)
        try await syncStremioLive(sources: liveSources, playlistId: playlistId, progress: progress)

        markStremioPlaylistUpdated(playlistId)
    }

    /// Cinemeta's browsable catalogs for the content types the addon can
    /// serve streams for. Mirrors the Stremio app, where Cinemeta is
    /// pre-installed and its Popular/Featured catalogs fill Discover while
    /// stream-focused addons (AIOStreams, Torrentio) contribute few or no
    /// catalogs of their own — without this, such a playlist browses only the
    /// addon's own short lists. Companion items resolve streams through the
    /// playlist's addon at playback time, so catalogs are only attached for
    /// types the addon declares IMDb-id stream support for. Skipped when the
    /// playlist already is Cinemeta; a companion failure just leaves the
    /// addon's own catalogs (never fails the sync).
    private func cinemetaCompanionSources(
        for manifest: StremioManifest
    ) async -> (movies: [StremioCatalogSource], series: [StremioCatalogSource]) {
        guard manifest.id != StremioClient.cinemetaAddonId else { return ([], []) }
        let wantsMovies = manifest.supportsStreams(forType: "movie", idPrefix: "tt")
        let wantsSeries = manifest.supportsStreams(forType: "series", idPrefix: "tt")
        guard wantsMovies || wantsSeries else { return ([], []) }

        let companion = StremioClient(
            configuration: StremioClient.Configuration(manifestURL: StremioClient.cinemetaManifestURL)
        )
        guard let catalogs = try? await companion.getManifest().catalogs.filter(\.isBrowsable) else {
            return ([], [])
        }
        func sources(ofType type: String) -> [StremioCatalogSource] {
            Self.catalogSources(
                client: companion,
                catalogs: catalogs.filter { $0.type == type },
                apiIdPrefix: "cinemeta:"
            )
        }
        return (
            movies: wantsMovies ? sources(ofType: "movie") : [],
            series: wantsSeries ? sources(ofType: "series") : []
        )
    }

    /// Walks a catalog's pages until it ends or the per-catalog cap is hit.
    /// A failing page is treated as the end of the catalog rather than a sync
    /// failure — per the protocol, an erroring addon just has no (more) results.
    private func fetchCatalogItems(source: StremioCatalogSource) async throws -> [StremioMeta] {
        try await Self.walkStremioCatalog(maxItems: Self.maxItemsPerCatalog) { skip in
            try Task.checkCancellation()
            return try? await source.client.getCatalog(type: source.catalog.type, id: source.catalog.id, skip: skip).metas
        }
    }

    /// The catalog paging loop, isolated from the network for testability.
    ///
    /// Real-world addons defeat every declared paging signal: page sizes vary
    /// (AIOStreams serves 99-item pages, Trakt-list addons 20), skip support
    /// often goes undeclared in the manifest, and addons without it either
    /// error on a skip request or ignore it and return the same page again. So
    /// instead of trusting the manifest or a fixed page size, keep requesting
    /// with `skip` and stop as soon as a page is missing, empty, or yields no
    /// ids that haven't been seen — which also terminates on skip-ignoring
    /// addons after one extra request.
    static func walkStremioCatalog(
        maxItems: Int,
        page: (_ skip: Int) async throws -> [StremioMeta]?
    ) async rethrows -> [StremioMeta] {
        var all: [StremioMeta] = []
        var seenIds = Set<String>()
        var skip = 0
        while all.count < maxItems {
            guard let metas = try await page(skip), !metas.isEmpty else { break }
            let fresh = metas.filter { seenIds.insert($0.id).inserted }
            guard !fresh.isEmpty else { break }
            all.append(contentsOf: fresh)
            skip += metas.count
        }
        return Array(all.prefix(maxItems))
    }

    // MARK: - Categories

    private func syncStremioCategories(_ sources: [StremioCatalogSource], type: CategoryType, playlistId: UUID) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let lookup = buildExistingCategoryLookup(context: context, playlistId: playlistId, type: type)
        guard let playlist = try context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        for (index, source) in sources.enumerated() {
            let apiId = source.categoryApiId
            let name = source.catalog.name ?? source.catalog.id.capitalized
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

        if !sources.isEmpty {
            pruneStaleCategories(
                playlistId: playlistId, type: type,
                seenApiIds: Set(sources.map(\.categoryApiId))
            )
        }
    }

    // MARK: - Movies

    private func syncStremioMovies(
        sources: [StremioCatalogSource],
        playlistId: UUID,
        progress: SyncProgress?
    ) async throws {
        await progress?.start(.movies)
        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.vod.rawValue)-"
        var seenIds = Set<String>()
        var imported = 0

        for source in sources {
            let metas = try await fetchCatalogItems(source: source)
            guard !metas.isEmpty else { continue }
            let categoryId = playlistPrefix + source.categoryApiId
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
        sources: [StremioCatalogSource],
        playlistId: UUID,
        progress: SyncProgress?
    ) async throws {
        await progress?.start(.series)
        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.series.rawValue)-"
        var seenIds = Set<String>()
        var imported = 0

        for source in sources {
            let metas = try await fetchCatalogItems(source: source)
            guard !metas.isEmpty else { continue }
            let categoryId = playlistPrefix + source.categoryApiId
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
    ///
    /// Stream-focused addons (AIOStreams, Torrentio) serve catalogs and
    /// streams but no `meta` resource — in the Stremio app, Cinemeta fills
    /// that gap for IMDb-keyed titles. Mirror that: when the addon can't
    /// produce the meta and the id is IMDb-shaped, ask Cinemeta instead.
    func fetchStremioEpisodes(seriesElementId: String, playlist: Playlist) async throws -> [ParsedEpisode] {
        let context = ModelContext(modelContainer)
        guard let stremioId = try context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == seriesElementId })
        ).first?.stremioId else { return [] }

        let client = StremioClient(configuration: StremioClient.Configuration(playlist: playlist))
        let meta: StremioMeta
        do {
            meta = try await client.getMeta(type: "series", id: stremioId).meta
        } catch where stremioId.hasPrefix("tt") {
            let cinemeta = StremioClient(
                configuration: StremioClient.Configuration(manifestURL: StremioClient.cinemetaManifestURL)
            )
            meta = try await cinemeta.getMeta(type: "series", id: stremioId).meta
        }

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
        sources: [StremioCatalogSource],
        playlistId: UUID,
        progress: SyncProgress?
    ) async throws {
        await progress?.start(.liveStreams)
        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.live.rawValue)-"
        var seenIds = Set<String>()
        var imported = 0

        for source in sources {
            let metas = try await fetchCatalogItems(source: source)
            guard !metas.isEmpty else { continue }
            let categoryId = playlistPrefix + source.categoryApiId
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

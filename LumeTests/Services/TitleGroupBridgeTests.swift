//
//  TitleGroupBridgeTests.swift
//  LumeTests
//
//  The bridge from a tmdbId-less row to the `tmdb:` group of its title. Runs
//  on a real store file, like `TitleGroupPrimariesTests`.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

/// A tmdbId-less row joins the `tmdb:` group its title's tmdbId carriers sit
/// in, and leaves it again when the last carrier goes.
struct TitleGroupBridgeTests {
    private func movie(
        _ id: String, _ name: String, tmdbId: Int? = nil, category: String, in context: ModelContext
    ) -> Movie {
        let movie = Movie(id: id, streamId: 0, name: name)
        movie.categoryId = category
        movie.tmdbId = tmdbId
        TitleGroupPrimaries.assignKey(to: movie)
        context.insert(movie)
        return movie
    }

    private func recompute(_ rows: [Movie], in context: ModelContext) {
        TitleGroupPrimaries.recompute(
            categoryKeys: TitleGroupPrimaries.Touched(movies: Set(rows.compactMap { TitleGroupPrimaries.RowState($0).categoryKey })),
            in: context,
            preferredLanguages: []
        )
    }

    /// Renames `row` through the Xtream sync's field copy, then recomputes
    /// and saves as a sync does.
    private func rename(_ row: Movie, to name: String, in context: ModelContext) async throws {
        let manager = ContentSyncManager(modelContainer: context.container)
        let dto = try FieldFixtures.decodeMovie(FieldFixtures.movieJSON(name: name, tmdb: "null", categoryId: "\"1\""))
        let before = TitleGroupPrimaries.RowState(row)
        await manager.applyMovieFields(from: dto, to: row, playlistPrefix: "M-vod-")
        var touched = TitleGroupPrimaries.Touched()
        TitleGroupPrimaries.note(before: before, after: row, into: &touched.movies)
        TitleGroupPrimaries.recompute(categoryKeys: touched, in: context, preferredLanguages: [])
        try context.save()
    }

    @Test func `a title carried by one tmdb id adopts its key without the id`() throws {
        try OnDiskCatalogStore.withContext { context in
            let carrier = movie("x-1", "The Matrix (1999)", tmdbId: 603, category: "X-vod-1", in: context)
            let copy = movie("m-1", "The Matrix (1999) 4K", category: "M-vod-1", in: context)
            recompute([carrier, copy], in: context)
            #expect(copy.titleGroupKey == "tmdb:603")
            #expect(copy.tmdbId == nil)
            #expect(copy.titleMatchKey == "t:the matrix|1999")
            #expect(copy.isCategoryGroupPrimary && carrier.isCategoryGroupPrimary)
        }
    }

    @Test func `two tmdb ids for one title leave the title row unbridged`() throws {
        try OnDiskCatalogStore.withContext { context in
            let first = movie("x-1", "Heat (1995)", tmdbId: 949, category: "X-vod-1", in: context)
            let second = movie("y-1", "Heat (1995)", tmdbId: 1_000_949, category: "Y-vod-1", in: context)
            let copy = movie("m-1", "Heat (1995) HD", category: "M-vod-1", in: context)
            recompute([first, second, copy], in: context)
            #expect(copy.titleGroupKey == "t:heat|1995")
        }
    }

    @Test func `a year-less title bridges only to a year-less carrier`() throws {
        try OnDiskCatalogStore.withContext { context in
            let heat = movie("x-1", "Heat", tmdbId: 949, category: "X-vod-1", in: context)
            let heatCopy = movie("m-1", "Heat FHD", category: "M-vod-1", in: context)
            let dune = movie("x-2", "Dune (2021)", tmdbId: 438_631, category: "X-vod-1", in: context)
            let oldDune = movie("m-2", "Dune (1984)", category: "M-vod-1", in: context)
            recompute([heat, heatCopy, dune, oldDune], in: context)
            #expect(heatCopy.titleGroupKey == "tmdb:949")
            #expect(oldDune.titleGroupKey == "t:dune|1984")
        }
    }

    @Test func `removing the last carrier reverts the adopter and re-elects`() throws {
        try OnDiskCatalogStore.withContext { context in
            let carrier = movie("x-1", "The Matrix (1999)", tmdbId: 603, category: "X-vod-1", in: context)
            let uhd = movie("m-1", "The Matrix (1999) 4K", category: "M-vod-1", in: context)
            let fhd = movie("m-2", "The Matrix (1999) FHD", category: "M-vod-1", in: context)
            recompute([carrier, uhd, fhd], in: context)
            try context.save()
            #expect(fhd.titleGroupKey == "tmdb:603")

            let removed = TitleGroupPrimaries.categoryKeys(of: [carrier])
            context.delete(carrier)
            TitleGroupPrimaries.recompute(categoryKeys: .init(movies: removed), in: context, preferredLanguages: [])
            try context.save()

            #expect(uhd.titleGroupKey == "t:the matrix|1999" && fhd.titleGroupKey == "t:the matrix|1999")
            #expect(uhd.isCategoryGroupPrimary && !fhd.isCategoryGroupPrimary)
        }
    }

    @Test func `a reverted adopter is queued for indexing again`() throws {
        try OnDiskCatalogStore.withContext { context in
            let carrier = movie("x-1", "The Matrix (1999)", tmdbId: 603, category: "X-vod-1", in: context)
            let copy = movie("m-1", "The Matrix (1999) 4K", category: "M-vod-1", in: context)
            let other = movie("m-2", "Alpha (2001)", category: "M-vod-1", in: context)
            recompute([carrier, copy, other], in: context)
            let indexed = Date()
            copy.indexedAt = indexed
            other.indexedAt = indexed
            try context.save()
            #expect(copy.titleGroupKey == "tmdb:603")

            let removed = TitleGroupPrimaries.categoryKeys(of: [carrier])
            context.delete(carrier)
            TitleGroupPrimaries.recompute(categoryKeys: .init(movies: removed), in: context, preferredLanguages: [])
            try context.save()

            #expect(copy.titleGroupKey == "t:the matrix|1999")
            #expect(copy.tmdbId == nil && copy.indexedAt == nil)
            #expect(other.indexedAt == indexed)
        }
    }

    @Test func `an adopter renamed to a title no carrier has is queued for indexing again`() async throws {
        try await OnDiskCatalogStore.withContext { context in
            let carrier = movie("x-1", "The Matrix (1999)", tmdbId: 603, category: "X-vod-1", in: context)
            let copy = movie("m-1", "The Matrix (1999) 4K", category: "M-vod-1", in: context)
            recompute([carrier, copy], in: context)
            copy.indexedAt = Date()
            try context.save()
            #expect(copy.titleGroupKey == "tmdb:603")

            try await rename(copy, to: "Alpha (2001)", in: context)

            #expect(copy.titleGroupKey == "t:alpha|2001")
            #expect(copy.tmdbId == nil && copy.indexedAt == nil)
        }
    }

    @Test func `an adopter renamed to a title one carrier has adopts its id`() async throws {
        try await OnDiskCatalogStore.withContext { context in
            let matrix = movie("x-1", "The Matrix (1999)", tmdbId: 603, category: "X-vod-1", in: context)
            let heat = movie("x-2", "Heat (1995)", tmdbId: 949, category: "X-vod-1", in: context)
            let copy = movie("m-1", "The Matrix (1999) 4K", category: "M-vod-1", in: context)
            recompute([matrix, heat, copy], in: context)
            copy.indexedAt = Date()
            try context.save()
            #expect(copy.titleGroupKey == "tmdb:603")

            try await rename(copy, to: "Heat (1995) HD", in: context)

            #expect(copy.titleGroupKey == "tmdb:949")
            #expect(copy.tmdbId == nil)
        }
    }

    @Test func `an adopter a second tmdb id makes ambiguous is queued for indexing again`() throws {
        try OnDiskCatalogStore.withContext { context in
            let first = movie("x-1", "Heat (1995)", tmdbId: 949, category: "X-vod-1", in: context)
            let copy = movie("m-1", "Heat (1995) HD", category: "M-vod-1", in: context)
            recompute([first, copy], in: context)
            copy.indexedAt = Date()
            try context.save()
            #expect(copy.titleGroupKey == "tmdb:949")

            let second = movie("y-1", "Heat (1995)", tmdbId: 1_000_949, category: "Y-vod-1", in: context)
            recompute([second], in: context)
            try context.save()

            #expect(copy.titleGroupKey == "t:heat|1995" && copy.indexedAt == nil)
        }
    }

    @Test func `a bridged series stays apart from movies`() throws {
        try OnDiskCatalogStore.withContext { context in
            let carrier = Series(id: "x-1", seriesId: 1, name: "Dark (2017)")
            carrier.categoryId = "X-series-1"
            carrier.tmdbId = 70523
            TitleGroupPrimaries.assignKey(to: carrier)
            context.insert(carrier)
            let copy = Series(id: "m-1", seriesId: 2, name: "Dark (2017)")
            copy.categoryId = "M-series-1"
            TitleGroupPrimaries.assignKey(to: copy)
            context.insert(copy)
            let film = movie("m-2", "Dark (2017)", category: "M-vod-1", in: context)
            TitleGroupPrimaries.recompute(
                categoryKeys: .init(
                    movies: TitleGroupPrimaries.categoryKeys(of: [film]),
                    series: TitleGroupPrimaries.categoryKeys(of: [carrier, copy])
                ),
                in: context,
                preferredLanguages: []
            )
            #expect(copy.titleGroupKey == "tmdb:70523")
            #expect(film.titleGroupKey == "t:dark|2017")
        }
    }
}

/// Both import orders converge on one group, and removing the tmdb playlist
/// hands the m3u copies back their own key.
struct TitleGroupBridgeImportTests {
    private struct World {
        let container: ModelContainer
        let directory: URL
        let xtream: Playlist
        let m3u: Playlist
        let m3uFile: URL
        let manager: ContentSyncManager
    }

    init() {
        clearM3UDigests()
    }

    private func makeWorld() throws -> World {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = OnDiskCatalogStore.catalogSchema
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema, url: directory.appendingPathComponent("catalog.store"), cloudKitDatabase: .none
            )
        )
        let host = "bridge-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(
            host: host,
            query: ("action", "get_vod_streams"),
            response: .init(body: """
            [{"stream_id":1,"name":"The Matrix (1999)","category_id":"1","tmdb":"603"},
             {"stream_id":2,"name":"Alpha (2001)","category_id":"1"},
             {"stream_id":3,"name":"Bravo (2002)","category_id":"1"}]
            """)
        )
        let m3uFile = directory.appendingPathComponent("bridge.m3u")
        try """
        #EXTM3U
        #EXTINF:-1 group-title="VOD | Movies",The Matrix (1999) FHD
        http://example.com/vod/matrix-fhd.mkv
        #EXTINF:-1 group-title="VOD | Movies",The Matrix (1999) 4K
        http://example.com/vod/matrix-4k.mkv
        """.write(to: m3uFile, atomically: true, encoding: .utf8)
        let context = ModelContext(container)
        let xtream = Playlist(name: "Xtream", serverURL: "http://\(host)", username: "u", password: "p")
        let m3u = Playlist(name: "M3U", m3uURL: m3uFile.absoluteString)
        context.insert(xtream)
        context.insert(m3u)
        try context.save()
        let client = XtreamClient(
            configuration: XtreamClient.Configuration(serverURL: "", username: "", password: ""),
            urlSession: StubURLProtocol.makeSession()
        )
        return World(
            container: container,
            directory: directory,
            xtream: xtream,
            m3u: m3u,
            m3uFile: m3uFile,
            manager: ContentSyncManager(modelContainer: container, xtreamClient: client)
        )
    }

    private func tearDown(_ world: World) {
        XtreamDigestStore.removeAll(playlistId: world.xtream.id)
        TitleGroupPrimaries.Deferred.clear(playlistId: world.xtream.id)
        TitleGroupPrimaries.Deferred.clear(playlistId: world.m3u.id)
        try? FileManager.default.removeItem(at: world.directory)
    }

    private func m3uCopies(_ world: World) throws -> [Movie] {
        let prefix = world.m3u.id.uuidString
        return try ModelContext(world.container).fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) }))
    }

    private func carrier(_ world: World) throws -> Movie? {
        try ModelContext(world.container).fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == 603 })).first
    }

    /// Exactly one primary per (category, key), and every row in a group.
    private func expectOnePrimaryPerGroup(_ world: World) throws {
        var counts: [String: Int] = [:]
        for movie in try ModelContext(world.container).fetch(FetchDescriptor<Movie>()) {
            let group = "\(movie.categoryId ?? "")|\(movie.titleGroupKey ?? "")"
            counts[group, default: 0] += movie.isCategoryGroupPrimary ? 1 : 0
        }
        #expect(counts.values.allSatisfy { $0 == 1 }, "\(counts)")
    }

    private func expectBridged(_ world: World) throws {
        let copies = try m3uCopies(world)
        #expect(copies.count == 2)
        #expect(copies.allSatisfy { $0.titleGroupKey == "tmdb:603" && $0.tmdbId == nil })
        #expect(try carrier(world)?.titleGroupKey == "tmdb:603")
        try expectOnePrimaryPerGroup(world)
        #expect(copies.filter(\.isCategoryGroupPrimary).map(\.name) == ["The Matrix (1999) 4K"])
    }

    @Test func `m3u after xtream adopts the tmdb key`() async throws {
        let world = try makeWorld()
        defer { tearDown(world) }
        try await world.manager.syncMovies(for: world.xtream, playlistId: world.xtream.id)
        try await world.manager.syncPlaylist(world.m3u)
        try expectBridged(world)
    }

    @Test func `xtream after m3u re-keys the stored copies`() async throws {
        let world = try makeWorld()
        defer { tearDown(world) }
        try await world.manager.syncPlaylist(world.m3u)
        #expect(try m3uCopies(world).allSatisfy { $0.titleGroupKey == "t:the matrix|1999" })
        try await world.manager.syncMovies(for: world.xtream, playlistId: world.xtream.id)
        try expectBridged(world)
    }

    @Test func `deleting the tmdb playlist reverts the copies`() async throws {
        let world = try makeWorld()
        defer { tearDown(world) }
        try await world.manager.syncMovies(for: world.xtream, playlistId: world.xtream.id)
        try await world.manager.syncPlaylist(world.m3u)

        let context = ModelContext(world.container)
        for copy in try m3uCopies(world) {
            let id = copy.id
            try #require(try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })).first).indexedAt = Date()
        }
        try context.save()
        let xtreamId = world.xtream.id
        let playlist = try #require(try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == xtreamId })).first)
        PlaylistDeletion.delete(playlist, in: context)
        try context.save()

        #expect(try carrier(world) == nil)
        #expect(try m3uCopies(world).allSatisfy {
            $0.titleGroupKey == "t:the matrix|1999" && $0.tmdbId == nil && $0.indexedAt == nil
        })
        try expectOnePrimaryPerGroup(world)
    }

    @Test func `pruning the carrier reverts the copies`() async throws {
        let world = try makeWorld()
        defer { tearDown(world) }
        try await world.manager.syncMovies(for: world.xtream, playlistId: world.xtream.id)
        try await world.manager.syncPlaylist(world.m3u)

        let prefix = world.xtream.id.uuidString
        let kept = try ModelContext(world.container).fetch(FetchDescriptor<Movie>(
            predicate: #Predicate { $0.id.starts(with: prefix) && $0.tmdbId == nil }
        ))
        await world.manager.pruneStaleMovies(playlistId: world.xtream.id, seenIds: Set(kept.map(\.id)))

        #expect(try carrier(world) == nil)
        #expect(try m3uCopies(world).allSatisfy { $0.titleGroupKey == "t:the matrix|1999" })
        try expectOnePrimaryPerGroup(world)
    }
}

//
//  TitleGroupBridgeEndToEndTests.swift
//  LumeTests
//
//  One small catalog imported twice, as an Xtream playlist that carries the
//  provider's tmdb ids and as an m3u playlist that carries none: in either
//  order every title ends up in one group, Search collapses it to one row, and
//  the source picker offers both copies.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct TitleGroupBridgeEndToEndTests {
    private struct World {
        let container: ModelContainer
        let directory: URL
        let xtream: Playlist
        let m3u: Playlist
        let manager: ContentSyncManager

        var scope: CatalogScope {
            .combined([xtream, m3u].map { (id: $0.id, tabs: Set(PlaylistTab.allCases)) })
        }
    }

    init() {
        clearM3UDigests()
    }

    private func registerFixtures(host: String, directory: URL) throws -> URL {
        StubURLProtocol.register(
            host: host,
            query: ("action", "get_vod_streams"),
            response: .init(body: """
            [{"stream_id":1,"name":"The Matrix (1999)","category_id":"1","tmdb":"603"},
             {"stream_id":2,"name":"Inception (2010)","category_id":"1","tmdb":"27205"}]
            """)
        )
        StubURLProtocol.register(
            host: host,
            query: ("action", "get_series"),
            response: .init(body: """
            [{"series_id":10,"name":"Breaking Bad","category_id":"2","tmdb":"1396"}]
            """)
        )
        let m3uFile = directory.appendingPathComponent("catalog.m3u")
        try """
        #EXTM3U
        #EXTINF:-1 group-title="VOD | Movies",The Matrix (1999) FHD
        http://example.com/vod/matrix.mkv
        #EXTINF:-1 group-title="VOD | Movies",Inception (2010) 4K
        http://example.com/vod/inception.mkv
        #EXTINF:-1 group-title="Series | Crime",Breaking Bad S01E01 Pilot
        http://example.com/series/bb-101.mkv
        #EXTINF:-1 group-title="Series | Crime",Breaking Bad S01E02 Cat's in the Bag
        http://example.com/series/bb-102.mkv
        """.write(to: m3uFile, atomically: true, encoding: .utf8)
        return m3uFile
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
        let host = "bridge-e2e-\(UUID().uuidString.lowercased()).test"
        let m3uFile = try registerFixtures(host: host, directory: directory)
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
            manager: ContentSyncManager(modelContainer: container, xtreamClient: client)
        )
    }

    private func tearDown(_ world: World) {
        XtreamDigestStore.removeAll(playlistId: world.xtream.id)
        TitleGroupPrimaries.Deferred.clear(playlistId: world.xtream.id)
        TitleGroupPrimaries.Deferred.clear(playlistId: world.m3u.id)
        try? FileManager.default.removeItem(at: world.directory)
    }

    private func syncXtream(_ world: World) async throws {
        try await world.manager.syncMovies(for: world.xtream, playlistId: world.xtream.id)
        try await world.manager.syncSeries(for: world.xtream, playlistId: world.xtream.id)
    }

    private func expectMerged(_ world: World) throws {
        let context = ModelContext(world.container)
        let movies = try context.fetch(FetchDescriptor<Movie>())
        let series = try context.fetch(FetchDescriptor<Series>())
        #expect(movies.count == 4)
        #expect(series.count == 2)

        let movieKeys = Dictionary(grouping: movies) { $0.titleGroupKey ?? "" }
        #expect(Set(movieKeys.keys) == ["tmdb:603", "tmdb:27205"])
        #expect(movieKeys.values.allSatisfy { $0.count == 2 })
        #expect(Set(series.map(\.titleGroupKey)) == ["tmdb:1396"])
        #expect(movies.filter { $0.id.hasPrefix(world.m3u.id.uuidString) }.allSatisfy { $0.tmdbId == nil })

        let ranking = TitleGrouping.Ranking(scope: world.scope, preferredLanguages: [])
        #expect(TitleGrouping.dedupe(movies, ranking: ranking, grouped: true).count == 2)
        #expect(TitleGrouping.dedupe(series, ranking: ranking, grouped: true).count == 1)

        for movie in movies {
            let sources = VODSourceResolver.sources(
                for: movie, scope: world.scope, isPremium: true, in: context, preferredLanguages: []
            )
            #expect(sources.count == 2, "\(movie.name)")
            #expect(Set(sources.map(\.playlistID)) == [world.xtream.id, world.m3u.id])
        }
        for show in series {
            let sources = VODSourceResolver.sources(
                for: show, scope: world.scope, isPremium: true, in: context, preferredLanguages: []
            )
            #expect(sources.count == 2, "\(show.name)")
        }
    }

    @Test func `xtream then m3u merges every title into one group with two sources`() async throws {
        let world = try makeWorld()
        defer { tearDown(world) }
        try await syncXtream(world)
        try await world.manager.syncPlaylist(world.m3u)
        try expectMerged(world)
    }

    @Test func `m3u then xtream merges every title into one group with two sources`() async throws {
        let world = try makeWorld()
        defer { tearDown(world) }
        try await world.manager.syncPlaylist(world.m3u)
        try await syncXtream(world)
        try expectMerged(world)
    }
}

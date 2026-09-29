//
//  XtreamDigestSkipTests.swift
//  LumeTests
//
//  A scheduled Xtream sync skips a bulk phase whose payload is byte-identical
//  to the one it last imported — and never when the rows that import left
//  behind are gone, or when the user asked for a full sync.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct XtreamDigestSkipTests {
    private struct World {
        let container: ModelContainer
        let manager: ContentSyncManager
        let playlist: Playlist
        let playlistId: UUID
        let host: String
    }

    private func makeWorld() throws -> World {
        let container = try makeTestContainer()
        let host = "xtream-digest-\(UUID().uuidString.lowercased()).test"
        let client = XtreamClient(
            configuration: XtreamClient.Configuration(serverURL: "", username: "", password: ""),
            urlSession: StubURLProtocol.makeSession()
        )
        let context = ModelContext(container)
        let playlist = Playlist(name: "Digest", serverURL: "http://\(host)", username: "u", password: "p")
        context.insert(playlist)
        try context.save()
        return World(
            container: container,
            manager: ContentSyncManager(modelContainer: container, xtreamClient: client),
            playlist: playlist,
            playlistId: playlist.id,
            host: host
        )
    }

    private func serveMovies(_ names: [String], in world: World) {
        let rows = names.enumerated().map { index, name in
            "{\"stream_id\":\(index + 1),\"name\":\"\(name)\",\"category_id\":\"1\"}"
        }
        StubURLProtocol.register(
            host: world.host,
            query: ("action", "get_vod_streams"),
            response: .init(body: "[" + rows.joined(separator: ",") + "]")
        )
    }

    private func movieNames(_ world: World) throws -> [String] {
        try ModelContext(world.container).fetch(
            FetchDescriptor<Movie>(sortBy: [SortDescriptor(\.streamId)])
        ).map(\.name)
    }

    /// Stamps a local edit an import would overwrite, so a test can tell a
    /// skipped phase from one that re-imported the same payload.
    private func renameFirstMovie(_ world: World) throws {
        let context = ModelContext(world.container)
        let movie = try #require(try context.fetch(FetchDescriptor<Movie>(sortBy: [SortDescriptor(\.streamId)])).first)
        movie.name = "Edited"
        try context.save()
    }

    @Test func `an unchanged payload skips the import`() async throws {
        let world = try makeWorld()
        defer { XtreamDigestStore.removeAll(playlistId: world.playlistId) }
        serveMovies(["Alpha", "Bravo"], in: world)

        try await world.manager.syncMovies(for: world.playlist, playlistId: world.playlistId, reuseUnchanged: true)
        try renameFirstMovie(world)
        try await world.manager.syncMovies(for: world.playlist, playlistId: world.playlistId, reuseUnchanged: true)

        #expect(try movieNames(world) == ["Edited", "Bravo"])
    }

    @Test func `a changed payload imports`() async throws {
        let world = try makeWorld()
        defer { XtreamDigestStore.removeAll(playlistId: world.playlistId) }
        serveMovies(["Alpha", "Bravo"], in: world)
        try await world.manager.syncMovies(for: world.playlist, playlistId: world.playlistId, reuseUnchanged: true)

        serveMovies(["Alpha", "Bravo", "Charlie"], in: world)
        try await world.manager.syncMovies(for: world.playlist, playlistId: world.playlistId, reuseUnchanged: true)

        #expect(try movieNames(world) == ["Alpha", "Bravo", "Charlie"])
    }

    @Test func `a full sync imports an unchanged payload`() async throws {
        let world = try makeWorld()
        defer { XtreamDigestStore.removeAll(playlistId: world.playlistId) }
        serveMovies(["Alpha", "Bravo"], in: world)
        try await world.manager.syncMovies(for: world.playlist, playlistId: world.playlistId, reuseUnchanged: true)

        try renameFirstMovie(world)
        try await world.manager.syncMovies(for: world.playlist, playlistId: world.playlistId, reuseUnchanged: false)

        #expect(try movieNames(world) == ["Alpha", "Bravo"])
    }

    @Test func `missing rows make the digest untrusted`() async throws {
        let world = try makeWorld()
        defer { XtreamDigestStore.removeAll(playlistId: world.playlistId) }
        serveMovies(["Alpha", "Bravo"], in: world)
        try await world.manager.syncMovies(for: world.playlist, playlistId: world.playlistId, reuseUnchanged: true)

        // The store lost a row the last import wrote; the bytes still match.
        let context = ModelContext(world.container)
        let first = try #require(try context.fetch(FetchDescriptor<Movie>(sortBy: [SortDescriptor(\.streamId)])).first)
        context.delete(first)
        try context.save()

        try await world.manager.syncMovies(for: world.playlist, playlistId: world.playlistId, reuseUnchanged: true)

        #expect(try movieNames(world) == ["Alpha", "Bravo"])
    }
}

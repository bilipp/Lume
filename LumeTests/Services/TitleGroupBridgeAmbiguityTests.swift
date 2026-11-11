//
//  TitleGroupBridgeAmbiguityTests.swift
//  LumeTests
//
//  A title two tmdb ids carry stays unbridged; once one of the ids leaves the
//  title (its playlist deleted, its row pruned, its row re-keyed), the
//  tmdbId-less copies adopt the id that is left.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct TitleGroupBridgeAmbiguityTests {
    private struct World {
        let container: ModelContainer
        let directory: URL
        let first: Playlist
        let second: Playlist
        let m3u: Playlist
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
        let first = Playlist(name: "First", serverURL: "http://first.test", username: "u", password: "p")
        let second = Playlist(name: "Second", serverURL: "http://second.test", username: "u", password: "p")
        let m3u = Playlist(name: "M3U", m3uURL: "file:///dev/null")
        let context = ModelContext(container)
        context.insert(first)
        context.insert(second)
        context.insert(m3u)

        let rows = [
            movie(in: first, "1", "Heat (1995)", tmdbId: 949, context: context),
            movie(in: second, "1", "Heat (1995)", tmdbId: 1_000_949, context: context),
            movie(in: second, "2", "Alpha (2001)", context: context),
            movie(in: m3u, "1", "Heat (1995) HD", context: context),
            movie(in: m3u, "2", "Heat (1995) 4K", context: context)
        ]
        TitleGroupPrimaries.recompute(
            categoryKeys: .init(movies: TitleGroupPrimaries.categoryKeys(of: rows)),
            in: context,
            preferredLanguages: []
        )
        try context.save()
        return World(container: container, directory: directory, first: first, second: second, m3u: m3u)
    }

    private func movie(in playlist: Playlist, _ id: String, _ name: String, tmdbId: Int? = nil, context: ModelContext) -> Movie {
        let prefix = playlist.id.uuidString
        let movie = Movie(id: "\(prefix)-movie-\(id)", streamId: Int(id) ?? 0, name: name)
        movie.categoryId = "\(prefix)-vod-1"
        movie.tmdbId = tmdbId
        TitleGroupPrimaries.assignKey(to: movie)
        context.insert(movie)
        return movie
    }

    private func copies(_ world: World) throws -> [Movie] {
        let prefix = world.m3u.id.uuidString
        return try ModelContext(world.container).fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) }))
    }

    private func expectOnePrimaryPerGroup(_ world: World) throws {
        var counts: [String: Int] = [:]
        for movie in try ModelContext(world.container).fetch(FetchDescriptor<Movie>()) {
            let group = "\(movie.categoryId ?? "")|\(movie.titleGroupKey ?? "")"
            counts[group, default: 0] += movie.isCategoryGroupPrimary ? 1 : 0
        }
        #expect(counts.values.allSatisfy { $0 == 1 }, "\(counts)")
    }

    private func expectAdopted(_ world: World, tmdbId: Int) throws {
        let copies = try copies(world)
        #expect(copies.count == 2)
        #expect(copies.allSatisfy { $0.titleGroupKey == "tmdb:\(tmdbId)" && $0.tmdbId == nil })
        #expect(copies.filter(\.isCategoryGroupPrimary).map(\.name) == ["Heat (1995) 4K"])
        try expectOnePrimaryPerGroup(world)
    }

    @Test func `two tmdb ids keep the copies on their title key`() throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.directory) }
        let copies = try copies(world)
        #expect(copies.allSatisfy { $0.titleGroupKey == "t:heat|1995" })
        #expect(copies.filter(\.isCategoryGroupPrimary).map(\.name) == ["Heat (1995) 4K"])
        try expectOnePrimaryPerGroup(world)
    }

    @Test func `deleting one carrier's playlist lets the copies adopt the other id`() throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.directory) }
        let context = ModelContext(world.container)
        let secondId = world.second.id
        let playlist = try #require(try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == secondId })).first)
        PlaylistDeletion.delete(playlist, in: context)
        try context.save()

        try expectAdopted(world, tmdbId: 949)
    }

    @Test func `pruning one carrier lets the copies adopt the other id`() async throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.directory) }
        let manager = ContentSyncManager(modelContainer: world.container)
        let kept: Set = ["\(world.second.id.uuidString)-movie-2"]
        await manager.pruneStaleMovies(playlistId: world.second.id, seenIds: kept)

        #expect(try ModelContext(world.container).fetchCount(FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == 1_000_949 })) == 0)
        try expectAdopted(world, tmdbId: 949)
    }

    @Test func `a carrier re-keyed off the title lets the copies adopt the other id`() throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.directory) }
        let context = ModelContext(world.container)
        let carrier = try #require(try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == 1_000_949 })).first)
        var touched = TitleGroupPrimaries.Touched()
        TitleGroupPrimaries.track(carrier, into: &touched.movies) {
            carrier.name = "Heat 2 (2026)"
            carrier.tmdbId = 2_000_949
            TitleGroupPrimaries.assignKey(to: carrier)
        }
        TitleGroupPrimaries.recompute(categoryKeys: touched, in: context, preferredLanguages: [])
        try context.save()

        try expectAdopted(world, tmdbId: 949)
    }

    @Test func `a carrier switching to the other id lets the copies adopt it`() throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.directory) }
        let context = ModelContext(world.container)
        let carrier = try #require(try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == 1_000_949 })).first)
        var touched = TitleGroupPrimaries.Touched()
        TitleGroupPrimaries.track(carrier, into: &touched.movies) {
            carrier.tmdbId = 949
            TitleGroupPrimaries.assignKey(to: carrier)
        }
        TitleGroupPrimaries.recompute(categoryKeys: touched, in: context, preferredLanguages: [])
        try context.save()

        try expectAdopted(world, tmdbId: 949)
    }
}

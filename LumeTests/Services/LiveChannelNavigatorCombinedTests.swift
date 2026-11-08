//
//  LiveChannelNavigatorCombinedTests.swift
//  LumeTests
//
//  In-player surfing launched from Combined: Favorites walks every member's
//  favorites, a category stays inside its own playlist, and a media value
//  without `surfScope` — every snapshot written before Combined — surfs its own
//  playlist as it always did. On disk: the combined ring is an `evaluate` fold,
//  which an in-memory store would evaluate in Swift and pass regardless.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct LiveChannelNavigatorCombinedTests {
    /// Three playlists, each with two favorited channels in its own category
    /// plus one unfavorited channel there. `favoriteOrder` interleaves the
    /// members so the combined ring alternates between them.
    private struct World {
        let first: Playlist
        let second: Playlist
        let outsider: Playlist

        var members: LiveSurfScope {
            LiveSurfScope(playlistIDs: [first.id, second.id])
        }
    }

    private func makeWorld(in context: ModelContext) throws -> World {
        let world = World(
            first: Playlist(name: "A", serverURL: "http://a.example.com:8080", username: "user-A", password: "p"),
            second: Playlist(name: "B", serverURL: "http://b.example.com:9090", username: "user-B", password: "p"),
            outsider: Playlist(name: "C", serverURL: "http://c.example.com", username: "user-C", password: "p")
        )
        for (rank, playlist) in [world.outsider, world.first, world.second].enumerated() {
            context.insert(playlist)
            for index in 0 ..< 3 {
                let stream = LiveStream(
                    id: streamID(playlist, index),
                    streamId: index,
                    name: "Channel \(rank)-\(index)",
                    num: index,
                    categoryId: category(of: playlist)
                )
                if index < 2 {
                    stream.isFavorite = true
                    // Outsider first, so a leaking scope would head the ring.
                    stream.favoriteOrder = index * 3 + rank
                }
                context.insert(stream)
            }
        }
        try context.save()
        return world
    }

    private func streamID(_ playlist: Playlist, _ index: Int) -> String {
        "\(playlist.id.uuidString)-live-\(index)"
    }

    private func category(of playlist: Playlist) -> String {
        "\(playlist.id.uuidString)-cat"
    }

    private func media(
        _ index: Int,
        of playlist: Playlist,
        scope: LiveChannelScope?,
        surfScope: LiveSurfScope?,
        in context: ModelContext
    ) throws -> PlayableMedia {
        let id = streamID(playlist, index)
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let stream = try #require(try context.fetch(descriptor).first)
        return try #require(PlayableMedia.from(stream: stream, playlist: playlist, scope: scope, surfScope: surfScope))
    }

    /// Every channel one full lap of `offset` presses visits from `start`.
    private func lap(from start: PlayableMedia, offset: Int, in context: ModelContext) -> [PlayableMedia] {
        var visited: [PlayableMedia] = []
        var current = start
        for _ in 0 ..< 10 {
            guard let next = LiveChannelNavigator.adjacentMedia(
                for: current, offset: offset, sort: .playlist, restriction: ContentRestriction(), in: context
            ) else { break }
            visited.append(next)
            if next.id == start.id { break }
            current = next
        }
        return visited
    }

    private func ids(_ media: [PlayableMedia]) -> [String] {
        media.compactMap {
            guard case let .live(id) = $0.contentRef else { return nil }
            return id
        }
    }

    // MARK: - Favorites

    @Test func `combined favorites walk every member in favorite order`() throws {
        try OnDiskCatalogStore.withContext { context in
            let world = try makeWorld(in: context)
            let start = try media(0, of: world.first, scope: .favorites, surfScope: world.members, in: context)

            let visited = lap(from: start, offset: 1, in: context)

            #expect(ids(visited) == [
                streamID(world.second, 0),
                streamID(world.first, 1),
                streamID(world.second, 1),
                streamID(world.first, 0)
            ])
        }
    }

    @Test func `combined favorites never reach a non member`() throws {
        try OnDiskCatalogStore.withContext { context in
            let world = try makeWorld(in: context)
            let start = try media(1, of: world.second, scope: .favorites, surfScope: world.members, in: context)

            let walked = ids(lap(from: start, offset: -1, in: context))

            #expect(walked.count == 4)
            #expect(!walked.contains { $0.hasPrefix(world.outsider.id.uuidString) })
        }
    }

    @Test func `a target in another member plays from that members server and keeps the scopes`() throws {
        try OnDiskCatalogStore.withContext { context in
            let world = try makeWorld(in: context)
            let start = try media(0, of: world.first, scope: .favorites, surfScope: world.members, in: context)

            let next = try #require(LiveChannelNavigator.adjacentMedia(
                for: start, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context
            ))

            #expect(next.contentRef == .live(streamID(world.second, 0)))
            #expect(next.url.host() == "b.example.com")
            #expect(next.url.absoluteString.contains("user-B"))
            #expect(next.channelScope == .favorites)
            #expect(next.surfScope == world.members)
        }
    }

    @Test func `favorites without a surf scope stay in the channels playlist`() throws {
        try OnDiskCatalogStore.withContext { context in
            let world = try makeWorld(in: context)
            let start = try media(0, of: world.first, scope: .favorites, surfScope: nil, in: context)

            #expect(ids(lap(from: start, offset: 1, in: context)) == [
                streamID(world.first, 1),
                streamID(world.first, 0)
            ])
        }
    }

    @Test func `a surf scope that no longer holds the channels playlist surfs that playlist alone`() throws {
        try OnDiskCatalogStore.withContext { context in
            let world = try makeWorld(in: context)
            let stale = LiveSurfScope(playlistIDs: [world.second.id, world.outsider.id])
            let start = try media(0, of: world.first, scope: .favorites, surfScope: stale, in: context)

            #expect(ids(lap(from: start, offset: 1, in: context)) == [
                streamID(world.first, 1),
                streamID(world.first, 0)
            ])
        }
    }

    // MARK: - Categories

    @Test func `category surfing stays in the channels own category`() throws {
        try OnDiskCatalogStore.withContext { context in
            let world = try makeWorld(in: context)
            let start = try media(
                0, of: world.first, scope: .category(category(of: world.first)), surfScope: world.members, in: context
            )

            let walked = ids(lap(from: start, offset: 1, in: context))

            #expect(walked == [streamID(world.first, 1), streamID(world.first, 2), streamID(world.first, 0)])
        }
    }

    // MARK: - Scope resolution

    @Test func `catalog scope spans members only for the virtual collections`() {
        let owner = UUID()
        let other = UUID()
        let members = LiveSurfScope(playlistIDs: [owner, other])

        let favorites = LiveChannelNavigator.catalogScope(for: .favorites, owner: owner, surfScope: members)
        let recents = LiveChannelNavigator.catalogScope(for: .recentlyWatched, owner: owner, surfScope: members)
        let category = LiveChannelNavigator.catalogScope(for: .category("c"), owner: owner, surfScope: members)
        let legacy = LiveChannelNavigator.catalogScope(for: .favorites, owner: owner, surfScope: nil)

        #expect(favorites.members(for: .liveTV) == [owner, other])
        #expect(recents.members(for: .liveTV) == [owner, other])
        #expect(category == .isolated(owner))
        #expect(legacy == .isolated(owner))
    }

    @Test func `isolated and single live member scopes carry no surf scope`() {
        let first = UUID()
        let second = UUID()

        let oneLiveMember = CatalogScope.combined([(id: first, tabs: [.liveTV]), (id: second, tabs: [.movies])])
        let twoLiveMembers = CatalogScope.combined([(id: second, tabs: [.liveTV]), (id: first, tabs: [.liveTV, .series])])

        #expect(LiveSurfScope(.isolated(first)) == nil)
        #expect(LiveSurfScope(.empty) == nil)
        #expect(LiveSurfScope(oneLiveMember) == nil)
        #expect(LiveSurfScope(twoLiveMembers)?.playlistIDs == [second, first])
    }
}

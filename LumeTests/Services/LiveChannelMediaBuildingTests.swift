//
//  LiveChannelMediaBuildingTests.swift
//  LumeTests
//
//  A live channel's URL carries its playlist's server and credentials, so it
//  must be built against the playlist that owns the channel — never the active
//  playlist, nor the playlist of the channel playing now.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct LiveChannelMediaBuildingTests {
    private func makePlaylist(_ name: String, server: String) -> Playlist {
        Playlist(name: name, serverURL: server, username: "user-\(name)", password: "pass")
    }

    private func makeStream(_ streamId: Int, in playlist: Playlist) -> LiveStream {
        LiveStream(
            id: "\(playlist.id.uuidString)-live-\(streamId)",
            streamId: streamId,
            name: "Channel \(streamId)",
            num: streamId,
            categoryId: "cat"
        )
    }

    private func makeSQLiteContainer() throws -> ModelContainer {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveChannelMediaBuilding-\(UUID().uuidString).store")
        let schema = Schema([Playlist.self, LiveStream.self])
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func `builds from the owning playlist whatever the order`() throws {
        let memberA = makePlaylist("A", server: "http://a.example.com:8080")
        let memberB = makePlaylist("B", server: "http://b.example.com:9090")
        let stream = makeStream(7, in: memberB)

        let media = try #require(PlayableMedia.from(stream: stream, ownedByOneOf: [memberA, memberB]))

        #expect(media.url.host() == "b.example.com")
        #expect(media.url.absoluteString.contains("user-B"))
        #expect(!media.url.absoluteString.contains("user-A"))
    }

    @Test func `carries the launch scope`() throws {
        let playlist = makePlaylist("A", server: "http://a.example.com:8080")
        let stream = makeStream(1, in: playlist)

        let media = try #require(PlayableMedia.from(stream: stream, ownedByOneOf: [playlist], scope: .favorites))

        #expect(media.channelScope == .favorites)
    }

    @Test func `unowned stream builds nothing`() {
        let memberA = makePlaylist("A", server: "http://a.example.com:8080")
        let removed = makePlaylist("Gone", server: "http://gone.example.com")
        let stream = makeStream(3, in: removed)

        #expect(PlayableMedia.from(stream: stream, ownedByOneOf: [memberA]) == nil)
    }

    @Test func `surf target from another member uses that members server`() throws {
        let container = try makeSQLiteContainer()
        let context = ModelContext(container)
        let memberA = makePlaylist("A", server: "http://a.example.com:8080")
        let memberB = makePlaylist("B", server: "http://b.example.com:9090")
        context.insert(memberA)
        context.insert(memberB)
        let target = makeStream(42, in: memberB)
        context.insert(target)
        try context.save()

        let media = try #require(
            LiveChannelNavigator.targetMedia(for: target, nextTo: memberA, scope: .favorites, in: context)
        )

        #expect(media.url.host() == "b.example.com")
        #expect(media.url.port == 9090)
        #expect(media.url.absoluteString.contains("user-B"))
        #expect(media.channelScope == .favorites)
    }

    @Test func `surf target without an installed owner builds nothing`() throws {
        let container = try makeSQLiteContainer()
        let context = ModelContext(container)
        let memberA = makePlaylist("A", server: "http://a.example.com:8080")
        context.insert(memberA)
        let orphan = makeStream(9, in: makePlaylist("Deleted", server: "http://deleted.example.com"))
        context.insert(orphan)
        try context.save()

        #expect(LiveChannelNavigator.targetMedia(for: orphan, nextTo: memberA, scope: nil, in: context) == nil)
    }
}

//
//  IntentEntityTests.swift
//  LumeTests
//
//  Siri's channel/movie/series entities: the id Siri hands back resolves to the
//  same catalog title, and an id the profile can no longer reach resolves to
//  nothing.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct IntentEntityTests {
    private func makeContainer() throws -> (ModelContainer, Playlist) {
        let schema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let playlist = Playlist(name: "Home", serverURL: "http://a.example", username: "u", password: "p")
        container.mainContext.insert(playlist)
        try container.mainContext.save()
        return (container, playlist)
    }

    private func resolver(_ container: ModelContainer, isChild: Bool = false) -> IntentCatalogResolver {
        IntentEntityLookup.resolver(
            container: container,
            session: .init(isPremium: true, isChildProfile: isChild, storedPlaylistID: "")
        )
    }

    @Test func `entity id round trips to the same catalog title`() throws {
        let (container, playlist) = try makeContainer()
        let channelID = "\(playlist.id.uuidString)-live-1"
        let movieID = "\(playlist.id.uuidString)-movie-1"
        container.mainContext.insert(LiveStream(id: channelID, streamId: 1, name: "DE | ZDF"))
        container.mainContext.insert(Movie(id: movieID, streamId: 1, name: "Heat"))
        try container.mainContext.save()

        let matched: [ChannelEntity] = IntentEntityLookup.entities(matching: "zdf", resolver: resolver(container))
        let channel = try #require(matched.first)
        #expect(channel.id == channelID)
        #expect(channel.title == "ZDF")

        let channels: [ChannelEntity] = IntentEntityLookup.entities(for: [channel.id], resolver: resolver(container))
        #expect(channels.map(\.id) == [channelID])
        #expect(channels.map(\.title) == ["ZDF"])

        let movies: [MovieEntity] = IntentEntityLookup.entities(for: [movieID], resolver: resolver(container))
        #expect(movies.map(\.id) == [movieID])
        let wrongKind: [SeriesEntity] = IntentEntityLookup.entities(for: [movieID], resolver: resolver(container))
        #expect(wrongKind.isEmpty)
    }

    @Test func `id lookup drops titles the profile can no longer reach`() throws {
        let (container, playlist) = try makeContainer()
        let restricted = Lume.Category(apiId: "1", name: "Adults", parentId: 0, type: .vod, playlist: playlist)
        restricted.isRestricted = true
        container.mainContext.insert(restricted)
        let movieID = "\(playlist.id.uuidString)-movie-1"
        container.mainContext.insert(Movie(id: movieID, streamId: 1, name: "Saw", categoryId: restricted.id))
        let hidden = LiveStream(id: "\(playlist.id.uuidString)-live-1", streamId: 1, name: "Arte")
        hidden.isHidden = true
        container.mainContext.insert(hidden)
        try container.mainContext.save()

        let child: [MovieEntity] = IntentEntityLookup.entities(for: [movieID], resolver: resolver(container, isChild: true))
        #expect(child.isEmpty)
        let parent: [MovieEntity] = IntentEntityLookup.entities(for: [movieID], resolver: resolver(container))
        #expect(parent.count == 1)
        let channels: [ChannelEntity] = IntentEntityLookup.entities(for: [hidden.id], resolver: resolver(container))
        #expect(channels.isEmpty)
    }
}

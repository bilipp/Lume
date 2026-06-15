//
//  PlaylistDeletionTests.swift
//  LumeTests
//
//  Verifies that deleting a playlist also removes the catalog content it brought
//  in (movies, series, live streams and their orphaned EPG listings), while
//  leaving other playlists' content untouched.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct PlaylistDeletionTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self,
            Lume.Category.self,
            LiveStream.self,
            Movie.self,
            Series.self,
            Episode.self,
            CastMember.self,
            EPGListing.self
        ])
        // `cloudKitDatabase: .none`: the catalog uses `@Attribute(.unique)`,
        // which CloudKit forbids and fails the load on a signed test host.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Seeds a playlist with one movie, one series (with an episode) and one live
    /// stream (with an EPG listing), all keyed by the playlist's id prefix.
    private func seed(_ playlist: Playlist, channelId: String, in context: ModelContext) {
        let prefix = playlist.id.uuidString
        context.insert(playlist)

        // `Category.id` is derived as "<playlist-uuid>-<type>-<apiId>".
        let category = Lume.Category(apiId: "1", name: "Movies", parentId: 0, type: .vod, playlist: playlist)
        context.insert(category)

        let movie = Movie(id: "\(prefix)-movie-1", streamId: 1, name: "A Movie", categoryId: "\(prefix)-vod-1")
        context.insert(movie)

        let series = Series(id: "\(prefix)-series-1", seriesId: 1, name: "A Series", categoryId: "\(prefix)-series-1")
        context.insert(series)
        let episode = Episode(id: "\(prefix)-series-1-e1", episodeId: "1", title: "E1", containerExtension: "mkv", seasonNum: 1, episodeNum: 1)
        context.insert(episode)
        series.episodes.append(episode)

        let stream = LiveStream(id: "\(prefix)-live-1", streamId: 1, name: "A Channel", epgChannelId: channelId, categoryId: "\(prefix)-live-1")
        context.insert(stream)

        let listing = EPGListing(
            id: "\(channelId)-1000",
            channelId: channelId,
            title: "Now Playing",
            listingDescription: "",
            start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 4600)
        )
        context.insert(listing)
    }

    @Test func `deleting a playlist removes its catalog content`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let playlist = Playlist(name: "Doomed", serverURL: "http://a.test", username: "u", password: "p")
        seed(playlist, channelId: "ch.a", in: context)
        try context.save()

        PlaylistDeletion.delete(playlist, in: context)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Playlist>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<LiveStream>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Lume.Category>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<EPGListing>()) == 0)
    }

    @Test func `deleting one playlist leaves another playlist's content intact`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let doomed = Playlist(name: "Doomed", serverURL: "http://a.test", username: "u", password: "p")
        let kept = Playlist(name: "Kept", serverURL: "http://b.test", username: "u", password: "p")
        seed(doomed, channelId: "ch.a", in: context)
        seed(kept, channelId: "ch.b", in: context)
        try context.save()

        PlaylistDeletion.delete(doomed, in: context)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Playlist>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<LiveStream>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<EPGListing>()) == 1)

        let keptPrefix = kept.id.uuidString
        let movie = try #require(try context.fetch(FetchDescriptor<Movie>()).first)
        #expect(movie.id.hasPrefix(keptPrefix))
    }

    @Test func `a channel shared with another playlist keeps its EPG`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // Both playlists carry a channel with the same epg id — deleting one
        // must not strip the guide listing the survivor still needs.
        let doomed = Playlist(name: "Doomed", serverURL: "http://a.test", username: "u", password: "p")
        let kept = Playlist(name: "Kept", serverURL: "http://b.test", username: "u", password: "p")
        seed(doomed, channelId: "shared.ch", in: context)
        seed(kept, channelId: "shared.ch", in: context)
        try context.save()

        PlaylistDeletion.delete(doomed, in: context)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<EPGListing>()) == 1)
    }
}

import Foundation
@testable import Lume
import SwiftData
import Testing

/// `PlayerStreamInfo` recovers the owning playlist from the content id alone —
/// every catalog id embeds the playlist's UUID as its 36-character prefix. The
/// not-found cases matter most: an earlier helper fell back to `playlists.first`
/// and confidently named the wrong provider on a multi-playlist install.
struct PlayerStreamInfoTests {
    /// One seeded container and the context it was seeded on. Everything a test
    /// inserts afterwards has to go through that same context: a `Category`
    /// built against a `Playlist` from another context is a cross-context
    /// reference SwiftData will not relate.
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let playlistA: Playlist
        let playlistB: Playlist
    }

    private func makeFixture() throws -> Fixture {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlistA = Playlist(name: "Provider A", serverURL: "http://a.test", username: "a", password: "a")
        let playlistB = Playlist(name: "Provider B", serverURL: "http://b.test", username: "b", password: "b")
        context.insert(playlistA)
        context.insert(playlistB)
        try context.save()
        return Fixture(container: container, context: context, playlistA: playlistA, playlistB: playlistB)
    }

    // MARK: - Playlist recovery

    @Test func `live stream resolves the owning playlist not another`() throws {
        let fixture = try makeFixture()
        let (container, context, playlistA) = (fixture.container, fixture.context, fixture.playlistA)
        let id = "\(playlistA.id.uuidString)-live-101"
        context.insert(LiveStream(id: id, streamId: 101, name: "Channel One"))
        try context.save()

        let details = PlayerStreamInfo.resolve(for: .live(id), container: container)
        #expect(details.playlistName == "Provider A")
    }

    @Test func `movie resolves the owning playlist not another`() throws {
        let fixture = try makeFixture()
        let (container, context, playlistB) = (fixture.container, fixture.context, fixture.playlistB)
        let id = "\(playlistB.id.uuidString)-movie-7"
        context.insert(Movie(id: id, streamId: 7, name: "A Film"))
        try context.save()

        let details = PlayerStreamInfo.resolve(for: .movie(id), container: container)
        #expect(details.playlistName == "Provider B")
    }

    @Test func `unknown playlist UUID resolves to nil not the first playlist`() throws {
        let container = try makeFixture().container
        let id = "\(UUID().uuidString)-live-999"

        let details = PlayerStreamInfo.resolve(for: .live(id), container: container)
        #expect(details.playlistName == nil)
    }

    @Test func `id without a UUID prefix resolves to nil`() throws {
        let container = try makeFixture().container

        let details = PlayerStreamInfo.resolve(for: .live("not-a-uuid-at-all-live-1"), container: container)
        #expect(details.playlistName == nil)
        #expect(details.categoryName == nil)
        #expect(details.epg == nil)
    }

    @Test func `episode resolves the playlist and leaves the rest nil`() throws {
        let fixture = try makeFixture()
        let (container, playlistA) = (fixture.container, fixture.playlistA)
        let id = "\(playlistA.id.uuidString)-episode-42"

        let details = PlayerStreamInfo.resolve(for: .episode(id), container: container)
        #expect(details.playlistName == "Provider A")
        #expect(details.categoryName == nil)
        #expect(details.epg == nil)
    }

    // MARK: - Live details

    @Test func `live stream resolves category and now next EPG`() throws {
        let fixture = try makeFixture()
        let (container, context, playlistA) = (fixture.container, fixture.context, fixture.playlistA)
        let category = Lume.Category(apiId: "5", name: "Sports", parentId: 0, type: .live, playlist: playlistA)
        context.insert(category)
        let id = "\(playlistA.id.uuidString)-live-101"
        context.insert(LiveStream(
            id: id,
            streamId: 101,
            name: "Channel One",
            epgChannelId: "chan.one",
            num: 12,
            categoryId: category.id
        ))
        let now = Date()
        context.insert(EPGListing(
            id: "epg-now",
            channelId: "chan.one",
            title: "Match of the Day",
            listingDescription: "",
            start: now.addingTimeInterval(-600),
            end: now.addingTimeInterval(600)
        ))
        context.insert(EPGListing(
            id: "epg-next",
            channelId: "chan.one",
            title: "Highlights",
            listingDescription: "",
            start: now.addingTimeInterval(600),
            end: now.addingTimeInterval(1200)
        ))
        try context.save()

        let details = PlayerStreamInfo.resolve(for: .live(id), container: container)
        #expect(details.playlistName == "Provider A")
        #expect(details.categoryName == "Sports")
        #expect(details.epg?.current?.title == "Match of the Day")
        #expect(details.epg?.next?.title == "Highlights")
    }

    @Test func `missing live stream still names the playlist`() throws {
        let fixture = try makeFixture()
        let (container, playlistA) = (fixture.container, fixture.playlistA)
        let id = "\(playlistA.id.uuidString)-live-404"

        let details = PlayerStreamInfo.resolve(for: .live(id), container: container)
        #expect(details.playlistName == "Provider A")
        #expect(details.epg == nil)
    }

    // MARK: - Movie details

    @Test func `movie resolves its category`() throws {
        let fixture = try makeFixture()
        let (container, context, playlistA) = (fixture.container, fixture.context, fixture.playlistA)
        let category = Lume.Category(apiId: "9", name: "Drama", parentId: 0, type: .vod, playlist: playlistA)
        context.insert(category)
        let id = "\(playlistA.id.uuidString)-movie-8"
        context.insert(Movie(id: id, streamId: 8, name: "A Film", categoryId: category.id))
        try context.save()

        let details = PlayerStreamInfo.resolve(for: .movie(id), container: container)
        #expect(details.categoryName == "Drama")
        #expect(details.epg == nil)
    }
}

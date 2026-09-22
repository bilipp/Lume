import Foundation
@testable import Lume
import SwiftData
import Testing

// MARK: - Deep-link round trip

/// `WidgetDeepLink` (LumeShared) builds the URLs the widgets emit; `DeepLink`
/// (app) parses them. These tests are the contract keeping the two in sync.
struct DeepLinkWidgetRoundTripTests {
    @Test func `play movie link round-trips`() throws {
        let url = try #require(WidgetDeepLink.play(kind: .movie, id: "ABC-123"))
        #expect(DeepLink(url: url) == .playMovie(id: "ABC-123"))
    }

    @Test func `play episode link round-trips`() throws {
        let url = try #require(WidgetDeepLink.play(kind: .episode, id: "ABC-9-1-2"))
        #expect(DeepLink(url: url) == .playEpisode(id: "ABC-9-1-2"))
    }

    @Test func `play live link round-trips`() throws {
        let url = try #require(WidgetDeepLink.play(kind: .live, id: "ABC-55"))
        #expect(DeepLink(url: url) == .playLive(id: "ABC-55"))
    }

    @Test func `open series link round-trips`() throws {
        let url = try #require(WidgetDeepLink.openSeries(id: "ABC-77"))
        #expect(DeepLink(url: url) == .openSeries(id: "ABC-77"))
    }

    @Test func `provider ids with reserved URL characters survive the round trip`() throws {
        let hostileID = "ABC-my show/№1 ?ep=2&x=ä"
        let url = try #require(WidgetDeepLink.play(kind: .live, id: hostileID))
        #expect(DeepLink(url: url) == .playLive(id: hostileID))
    }

    @Test func `a series cannot be a play target`() {
        #expect(WidgetDeepLink.play(kind: .series, id: "ABC-1") == nil)
    }

    @Test func `builder and parser agree on the scheme`() {
        #expect(WidgetDeepLink.scheme == DeepLink.scheme)
    }
}

// MARK: - Snapshot codability

struct WidgetSnapshotCodingTests {
    @Test func `snapshot survives an encode-decode round trip`() throws {
        let deepLink = try #require(WidgetDeepLink.play(kind: .movie, id: "p-1"))
        let snapshot = WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            continueWatching: [WidgetMediaItem(
                id: "movie-p-1", kind: .movie, title: "A", subtitle: "2024",
                imageURL: URL(string: "https://example.com/a.jpg"), progress: 0.5, deepLink: deepLink
            )],
            favorites: [],
            onNow: [WidgetChannelNow(
                id: "p-2", channelName: "News", logoURL: nil,
                nowTitle: "Now", nowStart: Date(timeIntervalSince1970: 1_700_000_000),
                nowEnd: Date(timeIntervalSince1970: 1_700_003_600),
                nextTitle: "Next", nextStart: Date(timeIntervalSince1970: 1_700_003_600),
                deepLink: deepLink
            )]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: encoder.encode(snapshot))
        #expect(decoded == snapshot)
    }
}

// MARK: - Exporter

@MainActor
struct WidgetSnapshotExporterTests {
    /// One playlist with resumable, watched, favorite and EPG-backed content.
    private func seedContainer() throws -> (ModelContainer, Playlist) {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "Test", serverURL: "http://example.com", username: "u", password: "p")
        context.insert(playlist)
        let prefix = playlist.id.uuidString

        let resumable = Movie(id: "\(prefix)-m1", streamId: 1, name: "Resumable", streamIcon: "https://img/m1.jpg")
        resumable.durationSecs = 3600
        resumable.watchProgress = 900
        resumable.lastWatchedDate = Date(timeIntervalSinceNow: -3600)
        context.insert(resumable)

        let watched = Movie(id: "\(prefix)-m2", streamId: 2, name: "Watched")
        watched.isWatched = true
        watched.watchProgress = 3600
        watched.lastWatchedDate = Date(timeIntervalSinceNow: -7200)
        context.insert(watched)

        let favoriteMovie = Movie(id: "\(prefix)-m3", streamId: 3, name: "Favorite Movie")
        favoriteMovie.isFavorite = true
        favoriteMovie.favoriteOrder = 1
        context.insert(favoriteMovie)

        let series = Series(id: "\(prefix)-s1", seriesId: 10, name: "Show")
        series.lastWatchedDate = Date(timeIntervalSinceNow: -60)
        series.isFavorite = true
        series.favoriteOrder = 0
        context.insert(series)
        let episodeDone = Episode(id: "\(prefix)-s1-1-1", episodeId: "e1", title: "Pilot", containerExtension: "mp4", seasonNum: 1, episodeNum: 1, series: series)
        episodeDone.setWatched(true)
        context.insert(episodeDone)
        let episodeInProgress = Episode(id: "\(prefix)-s1-1-2", episodeId: "e2", title: "Second", containerExtension: "mp4", seasonNum: 1, episodeNum: 2, series: series)
        episodeInProgress.durationSecs = 1200
        episodeInProgress.watchProgress = 600
        episodeInProgress.lastWatchedDate = Date(timeIntervalSinceNow: -60)
        context.insert(episodeInProgress)

        let channel = LiveStream(id: "\(prefix)-l1", streamId: 100, name: "News 24", streamIcon: "https://img/l1.png", epgChannelId: "news24.example")
        channel.isFavorite = true
        channel.favoriteOrder = 2
        context.insert(channel)

        let now = Date()
        context.insert(EPGListing(id: "epg-1", channelId: "news24.example", title: "Evening News", listingDescription: "", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1200)))
        context.insert(EPGListing(id: "epg-2", channelId: "news24.example", title: "Weather", listingDescription: "", start: now.addingTimeInterval(1200), end: now.addingTimeInterval(2400)))

        try context.save()
        return (container, playlist)
    }

    @Test func `continue watching resumes movies and the series' in-progress episode`() throws {
        let (container, playlist) = try seedContainer()
        let snapshot = WidgetSnapshotExporter.makeSnapshot(
            container: container, storedPlaylistID: playlist.id.uuidString, isChildProfile: false
        )

        // The series was watched more recently than the movie.
        #expect(snapshot.continueWatching.map(\.kind) == [.episode, .movie])
        let episode = try #require(snapshot.continueWatching.first)
        #expect(episode.title == "Show")
        #expect(episode.subtitle == "S1 E2 · Second")
        #expect(episode.progress == 0.5)
        let movie = try #require(snapshot.continueWatching.last)
        #expect(movie.title == "Resumable")
        #expect(movie.progress == 0.25)
        // The fully-watched movie must not resurface.
        #expect(!snapshot.continueWatching.contains { $0.title == "Watched" })
    }

    @Test func `favorites interleave kinds in unified order`() throws {
        let (container, playlist) = try seedContainer()
        let snapshot = WidgetSnapshotExporter.makeSnapshot(
            container: container, storedPlaylistID: playlist.id.uuidString, isChildProfile: false
        )

        #expect(snapshot.favorites.map(\.title) == ["Show", "Favorite Movie", "News 24"])
        #expect(snapshot.favorites.map(\.kind) == [.series, .movie, .live])
    }

    @Test func `on now carries the current and next programme`() throws {
        let (container, playlist) = try seedContainer()
        let snapshot = WidgetSnapshotExporter.makeSnapshot(
            container: container, storedPlaylistID: playlist.id.uuidString, isChildProfile: false
        )

        let channel = try #require(snapshot.onNow.first)
        #expect(channel.channelName == "News 24")
        #expect(channel.nowTitle == "Evening News")
        #expect(channel.nextTitle == "Weather")
    }

    @Test func `a child profile keeps restricted categories out of the snapshot`() throws {
        let (container, playlist) = try seedContainer()
        let context = container.mainContext
        let restricted = Lume.Category(apiId: "9", name: "Adults", parentId: 0, type: .vod, playlist: playlist)
        restricted.isRestricted = true
        context.insert(restricted)
        let hidden = Movie(id: "\(playlist.id.uuidString)-m9", streamId: 9, name: "Hidden", categoryId: restricted.id)
        hidden.isFavorite = true
        hidden.durationSecs = 3600
        hidden.watchProgress = 600
        hidden.lastWatchedDate = Date()
        context.insert(hidden)
        try context.save()

        let adult = WidgetSnapshotExporter.makeSnapshot(
            container: container, storedPlaylistID: playlist.id.uuidString, isChildProfile: false
        )
        #expect(adult.favorites.contains { $0.title == "Hidden" })

        let child = WidgetSnapshotExporter.makeSnapshot(
            container: container, storedPlaylistID: playlist.id.uuidString, isChildProfile: true
        )
        #expect(!child.favorites.contains { $0.title == "Hidden" })
        #expect(!child.continueWatching.contains { $0.title == "Hidden" })
    }

    @Test func `content from other playlists is excluded`() throws {
        let (container, playlist) = try seedContainer()
        let context = container.mainContext
        let foreign = Movie(id: "\(UUID().uuidString)-x1", streamId: 50, name: "Foreign")
        foreign.isFavorite = true
        foreign.durationSecs = 3600
        foreign.watchProgress = 60
        foreign.lastWatchedDate = Date()
        context.insert(foreign)
        try context.save()

        let snapshot = WidgetSnapshotExporter.makeSnapshot(
            container: container, storedPlaylistID: playlist.id.uuidString, isChildProfile: false
        )
        #expect(!snapshot.favorites.contains { $0.title == "Foreign" })
        #expect(!snapshot.continueWatching.contains { $0.title == "Foreign" })
    }

    @Test func `no playlists produces an empty snapshot`() throws {
        let container = try makeTestContainer()
        let snapshot = WidgetSnapshotExporter.makeSnapshot(
            container: container, storedPlaylistID: "", isChildProfile: false
        )
        #expect(snapshot.continueWatching.isEmpty)
        #expect(snapshot.favorites.isEmpty)
        #expect(snapshot.onNow.isEmpty)
    }
}

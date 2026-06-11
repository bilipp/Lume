//
//  M3USyncTests.swift
//  LumeTests
//
//  End-to-end tests for the m3u sync pipeline: a local playlist file is synced
//  through the real ContentSyncManager into an in-memory store.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct M3USyncTests {
    // MARK: - Fixtures

    private func writeTempFile(_ content: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let mixedPlaylist = """
    #EXTM3U url-tvg="http://example.com/embedded-guide.xml"
    #EXTINF:-1 tvg-id="news.1" tvg-logo="http://example.com/news1.png" group-title="News",News One
    http://example.com/live/news1.ts
    #EXTINF:-1 tvg-id="sport.1" group-title="Sports",Sport One
    http://example.com/live/sport1.m3u8
    #EXTINF:-1 group-title="General",Ungrouped Extras
    http://example.com/live/extra
    #EXTINF:-1 tvg-logo="http://example.com/film.png" group-title="VOD | Action",Die Hard
    http://example.com/movie/u/p/1001.mp4
    #EXTINF:-1 group-title="VOD | Drama",The Godfather
    http://example.com/vod/godfather.mkv
    #EXTINF:-1 group-title="Series | Crime",Breaking Bad S01E01 Pilot
    http://example.com/series/u/p/2001.mp4
    #EXTINF:-1 group-title="Series | Crime",Breaking Bad S01E02 Cat's in the Bag...
    http://example.com/series/u/p/2002.mp4
    #EXTINF:-1 group-title="Series | Crime",Breaking Bad S02E01 Seven Thirty-Seven
    http://example.com/series/u/p/2003.mp4
    """

    /// Creates a store with one m3u playlist pointing at a local file.
    private func makePlaylist(container: ModelContainer, fileURL: URL, epgURL: String? = nil) throws -> Playlist {
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test M3U", m3uURL: fileURL.absoluteString, epgURL: epgURL)
        context.insert(playlist)
        try context.save()
        return playlist
    }

    // MARK: - Tests

    @Test func `syncs mixed playlist into unified models`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(mixedPlaylist, ext: "m3u")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)
        let playlistId = playlist.id

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)

        let streams = try context.fetch(FetchDescriptor<LiveStream>())
        #expect(streams.count == 3)
        let newsOne = try #require(streams.first { $0.name == "News One" })
        #expect(newsOne.directURL == "http://example.com/live/news1.ts")
        #expect(newsOne.epgChannelId == "news.1")
        #expect(newsOne.streamIcon == "http://example.com/news1.png")
        #expect(newsOne.categoryId == "\(playlistId.uuidString)-live-News")
        let ungrouped = try #require(streams.first { $0.name == "Ungrouped Extras" })
        #expect(ungrouped.categoryId == "\(playlistId.uuidString)-live-General")

        let movies = try context.fetch(FetchDescriptor<Movie>())
        #expect(movies.count == 2)
        let dieHard = try #require(movies.first { $0.name == "Die Hard" })
        #expect(dieHard.directURL == "http://example.com/movie/u/p/1001.mp4")
        #expect(dieHard.categoryId == "\(playlistId.uuidString)-vod-VOD | Action")

        let series = try context.fetch(FetchDescriptor<Series>())
        #expect(series.count == 1)
        let breakingBad = try #require(series.first)
        #expect(breakingBad.name == "Breaking Bad")
        #expect(breakingBad.episodes.count == 3)
        let pilot = try #require(breakingBad.episodes.first { $0.seasonNum == 1 && $0.episodeNum == 1 })
        #expect(pilot.title == "Pilot")
        #expect(pilot.directSource == "http://example.com/series/u/p/2001.mp4")

        let categories = try context.fetch(FetchDescriptor<Lume.Category>())
        #expect(categories.count == 6) // News, Sports, General (live) + 2 VOD + 1 series
        let categoryNames = Set(categories.map(\.name))
        #expect(categoryNames.contains("Series | Crime"))

        // The playlist's url-tvg header is adopted when no EPG URL was given.
        let storedPlaylist = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(storedPlaylist.epgURL == "http://example.com/embedded-guide.xml")
        #expect(storedPlaylist.syncStatus == .idle)
        #expect(storedPlaylist.lastSyncDate != nil)
    }

    @Test func `re-sync is idempotent and preserves user state`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(mixedPlaylist, ext: "m3u")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(playlist)

        // Mark user state between syncs.
        do {
            let context = ModelContext(container)
            let stream = try #require(try context.fetch(FetchDescriptor<LiveStream>()).first { $0.name == "News One" })
            stream.isFavorite = true
            let category = try #require(try context.fetch(FetchDescriptor<Lume.Category>()).first { $0.name == "News" })
            category.isHidden = true
            try context.save()
        }

        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<LiveStream>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<Lume.Category>()) == 6)

        let stream = try #require(try context.fetch(FetchDescriptor<LiveStream>()).first { $0.name == "News One" })
        #expect(stream.isFavorite, "Re-sync must not wipe favorites")
        let category = try #require(try context.fetch(FetchDescriptor<Lume.Category>()).first { $0.name == "News" })
        #expect(category.isHidden, "Re-sync must not wipe hidden state")
    }

    @Test func `imports EPG from explicit XMLTV URL`() async throws {
        let xmltv = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="20260611120000 +0000" stop="20260611130000 +0000" channel="news.1">
            <title>Midday News</title>
            <desc>Headlines at noon.</desc>
          </programme>
          <programme start="20260611120000 +0000" stop="20260611140000 +0000" channel="unknown.channel">
            <title>Should be filtered</title>
          </programme>
        </tv>
        """
        let container = try makeTestContainer()
        let playlistFile = try writeTempFile(mixedPlaylist, ext: "m3u")
        let epgFile = try writeTempFile(xmltv, ext: "xml")
        defer {
            try? FileManager.default.removeItem(at: playlistFile)
            try? FileManager.default.removeItem(at: epgFile)
        }
        let playlist = try makePlaylist(container: container, fileURL: playlistFile, epgURL: epgFile.absoluteString)

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)
        let listings = try context.fetch(FetchDescriptor<EPGListing>())
        #expect(listings.count == 1, "Only programmes for known tvg-ids are imported")
        #expect(listings.first?.title == "Midday News")
        #expect(listings.first?.channelId == "news.1")
    }

    // MARK: - Scale

    /// The user-facing requirement: playlists with a huge number of entries
    /// must import completely, in bounded time, without ballooning memory
    /// (batched contexts — the parser never holds the file in memory).
    @Test func `syncs a 100k-entry playlist in bounded time`() async throws {
        var content = "#EXTM3U\n"
        content.reserveCapacity(16_000_000)
        let liveCount = 80000
        let movieCount = 20000
        for index in 0 ..< liveCount {
            content += "#EXTINF:-1 tvg-id=\"chan.\(index)\" group-title=\"Group \(index % 50)\",Channel \(index)\n"
            content += "http://example.com/live/\(index).ts\n"
        }
        for index in 0 ..< movieCount {
            content += "#EXTINF:-1 group-title=\"VOD \(index % 20)\",Movie \(index)\n"
            content += "http://example.com/vod/\(index).mp4\n"
        }

        let container = try makeTestContainer()
        let fileURL = try writeTempFile(content, ext: "m3u")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)

        let manager = ContentSyncManager(modelContainer: container)
        let start = ContinuousClock.now
        try await manager.syncPlaylist(playlist)
        let elapsed = ContinuousClock.now - start

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<LiveStream>()) == liveCount)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == movieCount)
        #expect(try context.fetchCount(FetchDescriptor<Lume.Category>()) == 70)

        let seconds = elapsed.components.seconds
        #expect(seconds < 120, "100k-entry sync took \(seconds)s — expected < 120s")
    }
}

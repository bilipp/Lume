//
//  ContentSyncDisabledContentTests.swift
//  LumeTests
//
//  A playlist that stops fetching a kind (`Playlist.disabledContent`): the
//  sync skips it, what an earlier sync brought in goes, the other kinds stay,
//  and switching it back on brings the content back.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct ContentSyncDisabledContentTests {
    init() {
        clearM3UDigests()
    }

    // MARK: - Fixtures

    private func writeTempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m3u")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let mixedPlaylist = """
    #EXTM3U
    #EXTINF:-1 tvg-id="news.1" group-title="News",News One
    http://example.com/live/news1.ts
    #EXTINF:-1 group-title="Sports",Sport One
    http://example.com/live/sport1.m3u8
    #EXTINF:-1 group-title="VOD | Action",Die Hard
    http://example.com/movie/u/p/1001.mp4
    #EXTINF:-1 group-title="VOD | Drama",The Godfather
    http://example.com/vod/godfather.mkv
    #EXTINF:-1 group-title="Series | Crime",Breaking Bad S01E01 Pilot
    http://example.com/series/u/p/2001.mp4
    #EXTINF:-1 group-title="Series | Crime",Breaking Bad S01E02 Cat's in the Bag...
    http://example.com/series/u/p/2002.mp4
    """

    private func makeM3UPlaylist(container: ModelContainer, fileURL: URL, disabled: Set<PlaylistTab> = []) throws -> Playlist {
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test M3U", m3uURL: fileURL.absoluteString)
        playlist.disabledContent = disabled
        context.insert(playlist)
        try context.save()
        return playlist
    }

    private struct Counts: Equatable {
        var live: Int
        var movies: Int
        var series: Int
        var episodes: Int
        var categories: [CategoryType: Int]
    }

    private func counts(_ container: ModelContainer) throws -> Counts {
        let context = ModelContext(container)
        let categories = try context.fetch(FetchDescriptor<Lume.Category>())
        return try Counts(
            live: context.fetchCount(FetchDescriptor<LiveStream>()),
            movies: context.fetchCount(FetchDescriptor<Movie>()),
            series: context.fetchCount(FetchDescriptor<Series>()),
            episodes: context.fetchCount(FetchDescriptor<Episode>()),
            categories: Dictionary(grouping: categories, by: \.type).mapValues(\.count)
        )
    }

    // MARK: - m3u pipeline

    @Test func `an m3u sync skips movies the playlist doesn't fetch`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(mixedPlaylist)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makeM3UPlaylist(container: container, fileURL: fileURL, disabled: [.movies])

        try await ContentSyncManager(modelContainer: container).syncPlaylist(playlist)

        let result = try counts(container)
        #expect(result.movies == 0)
        #expect(result.categories[.vod] == nil)
        #expect(result.live == 2)
        #expect(result.series == 1)
        #expect(result.episodes == 2)
        #expect(result.categories[.live] == 2)
        #expect(result.categories[.series] == 1)
    }

    @Test func `an m3u sync skips series and their episodes the playlist doesn't fetch`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(mixedPlaylist)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makeM3UPlaylist(container: container, fileURL: fileURL, disabled: [.series, .liveTV])

        try await ContentSyncManager(modelContainer: container).syncPlaylist(playlist)

        let result = try counts(container)
        #expect(result.series == 0)
        #expect(result.episodes == 0)
        #expect(result.live == 0)
        #expect(result.movies == 2)
        #expect(result.categories == [.vod: 2])
    }

    @Test func `switching a kind off removes what an earlier sync imported, and on brings it back`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(mixedPlaylist)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makeM3UPlaylist(container: container, fileURL: fileURL)
        let manager = ContentSyncManager(modelContainer: container)

        try await manager.syncPlaylist(playlist)
        #expect(try counts(container).live == 2)

        // Off: the next sync removes the channels and their categories even
        // though the file itself hasn't changed. The switch in Settings clears
        // the file fingerprint for exactly that reason.
        let context = ModelContext(container)
        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        stored.disabledContent = [.liveTV]
        try context.save()
        M3UDigestStore.remove(playlistId: playlist.id)
        try await manager.syncPlaylist(playlist)

        var result = try counts(container)
        #expect(result.live == 0)
        #expect(result.categories[.live] == nil)
        #expect(result.movies == 2)
        #expect(result.series == 1)

        // On again: a full import, as if the channels were new.
        stored.disabledContent = []
        try context.save()
        M3UDigestStore.remove(playlistId: playlist.id)
        try await manager.syncPlaylist(playlist)

        result = try counts(container)
        #expect(result.live == 2)
        #expect(result.categories[.live] == 2)
    }

    @Test func `a sync of a playlist that fetches everything removes nothing`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(mixedPlaylist)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makeM3UPlaylist(container: container, fileURL: fileURL)

        try await ContentSyncManager(modelContainer: container).syncPlaylist(playlist)

        let result = try counts(container)
        #expect(result == Counts(live: 2, movies: 2, series: 1, episodes: 2, categories: [.live: 2, .vod: 2, .series: 1]))
    }

    // MARK: - Removal, as every pipeline runs it after its phases

    private func insertXtreamCatalog(playlistId: UUID, container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let playlist = Playlist(name: "X", serverURL: "http://x", username: "u", password: "p")
        playlist.id = playlistId
        context.insert(playlist)
        let prefix = playlistId.uuidString
        for type in CategoryType.allCases {
            context.insert(Lume.Category(
                apiId: "1", name: "\(type.rawValue) 1", parentId: 0, typeRaw: type.rawValue, playlist: playlist
            ))
        }
        for index in 1 ... 3 {
            context.insert(Movie(id: "\(prefix)-movie-\(index)", streamId: index, name: "Movie \(index)"))
            context.insert(LiveStream(id: "\(prefix)-live-\(index)", streamId: index, name: "Channel \(index)"))
            let series = Series(id: "\(prefix)-series-\(index)", seriesId: index, name: "Show \(index)")
            context.insert(series)
            context.insert(Episode(
                id: "\(prefix)-episode-\(index)", episodeId: "\(index)", title: "Pilot", containerExtension: "mp4",
                seasonNum: 1, episodeNum: 1, series: series
            ))
        }
        try context.save()
    }

    @Test func `removing a kind leaves the other kinds and other playlists alone`() async throws {
        let container = try makeTestContainer()
        let mine = UUID()
        let other = UUID()
        try insertXtreamCatalog(playlistId: mine, container: container)
        try insertXtreamCatalog(playlistId: other, container: container)
        let manager = ContentSyncManager(modelContainer: container)

        await manager.removeDisabledContent(playlistId: mine, disabled: [.series])

        let context = ModelContext(container)
        let series = try context.fetch(FetchDescriptor<Series>())
        #expect(series.count == 3)
        #expect(series.allSatisfy { $0.id.hasPrefix(other.uuidString) })
        // Episodes cascade from their series.
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 6)
        #expect(try context.fetchCount(FetchDescriptor<LiveStream>()) == 6)
        let categories = try context.fetch(FetchDescriptor<Lume.Category>())
        #expect(categories.count == 5)
        #expect(!categories.contains { $0.id == "\(mine.uuidString)-series-1" })
        #expect(categories.contains { $0.id == "\(other.uuidString)-series-1" })
    }

    @Test func `removing live TV also drops the kind's Xtream digest`() async throws {
        let container = try makeTestContainer()
        let mine = UUID()
        try insertXtreamCatalog(playlistId: mine, container: container)
        XtreamDigestStore.store(.init(digest: "abc", rowCount: 3), playlistId: mine, endpoint: .live)
        XtreamDigestStore.store(.init(digest: "def", rowCount: 3), playlistId: mine, endpoint: .movies)
        defer { XtreamDigestStore.removeAll(playlistId: mine) }
        let manager = ContentSyncManager(modelContainer: container)

        await manager.removeDisabledContent(playlistId: mine, disabled: [.liveTV])

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<LiveStream>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 3)
        #expect(XtreamDigestStore.entry(playlistId: mine, endpoint: .live) == nil)
        #expect(XtreamDigestStore.entry(playlistId: mine, endpoint: .movies) != nil)
    }

    @Test func `nothing disabled is a no-op`() async throws {
        let container = try makeTestContainer()
        let mine = UUID()
        try insertXtreamCatalog(playlistId: mine, container: container)

        await ContentSyncManager(modelContainer: container).removeDisabledContent(playlistId: mine, disabled: [])

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<LiveStream>()) == 3)
    }

    // MARK: - Progress steps

    @Test func `the progress sheet lists only the steps a sync will run`() {
        #expect(SyncStep.steps(for: .xtream) == SyncStep.xtreamSteps)
        #expect(SyncStep.steps(for: .xtream, disabled: [.movies]) == [
            .authenticating, .seriesCategories, .liveCategories, .series, .liveStreams
        ])
        #expect(SyncStep.steps(for: .xtream, disabled: [.movies, .series, .liveTV]) == [.authenticating])
        #expect(SyncStep.steps(for: .stalker, full: true, disabled: [.liveTV]) == [
            .authenticating, .movieCategories, .seriesCategories, .movies, .series
        ])
        #expect(SyncStep.steps(for: .jellyfin, disabled: [.series]) == [.authenticating, .movies])
        // The m3u and WebDAV pipelines import in one pass; nothing to drop.
        #expect(SyncStep.steps(for: .m3u, disabled: [.movies]) == SyncStep.m3uSteps)
    }

    @Test func `a classified batch drops the kinds a playlist doesn't fetch`() {
        let entry = M3UEntry(name: "x", url: "http://x")
        let batch = M3UClassifiedBatch(live: [entry], movies: [entry, entry], episodes: [])
        let dropped = batch.dropping([.movies])
        #expect(dropped.live.count == 1)
        #expect(dropped.movies.isEmpty)
        #expect(batch.dropping([]).movies.count == 2)
    }
}

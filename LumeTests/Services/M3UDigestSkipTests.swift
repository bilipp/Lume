//
//  M3UDigestSkipTests.swift
//  LumeTests
//
//  Skip-if-unchanged for the m3u pipeline: a re-download whose bytes match the
//  last fully imported file must skip the import and the sweeps, while still
//  advancing the playlist's sync dates. Its own file rather than more of
//  M3USyncTests, which is already close to SwiftLint's type-body limit.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct M3UDigestSkipTests {
    /// Swift Testing runs this before every test in the suite. The m3u digest is
    /// device-local `UserDefaults` state that outlives a test, so each case
    /// starts from a clean slate rather than inheriting a sibling's fingerprint.
    init() {
        clearM3UDigests()
    }

    // MARK: - Fixtures

    private func writeTempFile(_ content: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let playlist = """
    #EXTM3U
    #EXTINF:-1 tvg-id="news.1" group-title="News",News One
    http://example.com/live/news1.ts
    #EXTINF:-1 group-title="Sports",Sport One
    http://example.com/live/sport1.m3u8
    #EXTINF:-1 group-title="VOD | Action",Die Hard
    http://example.com/movie/u/p/1001.mp4
    #EXTINF:-1 group-title="Series | Crime",Breaking Bad S01E01 Pilot
    http://example.com/series/u/p/2001.mp4
    """

    /// `playlist` plus one channel, so the file's bytes — and its digest —
    /// differ while everything already imported still appears.
    private let extendedPlaylist = """
    #EXTM3U
    #EXTINF:-1 tvg-id="news.1" group-title="News",News One
    http://example.com/live/news1.ts
    #EXTINF:-1 group-title="Sports",Sport One
    http://example.com/live/sport1.m3u8
    #EXTINF:-1 group-title="News",News Two
    http://example.com/live/news2.ts
    #EXTINF:-1 group-title="VOD | Action",Die Hard
    http://example.com/movie/u/p/1001.mp4
    #EXTINF:-1 group-title="Series | Crime",Breaking Bad S01E01 Pilot
    http://example.com/series/u/p/2001.mp4
    """

    private func makePlaylist(container: ModelContainer, fileURL: URL) throws -> Playlist {
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test M3U", m3uURL: fileURL.absoluteString)
        context.insert(playlist)
        try context.save()
        return playlist
    }

    /// The digest and the sweep counters live in `UserDefaults`, which outlives
    /// the store — every case clears its own keys so none leaks into the next.
    private func clearDefaults(playlistId: UUID) {
        M3UDigestStore.remove(playlistId: playlistId)
        SweepSkipDefaults.removeAll(playlistId: playlistId)
    }

    /// Removes one imported channel behind the sync's back. A skipped import
    /// leaves the hole; an import that actually ran fills it back in.
    private func deleteNewsOne(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let stream = try #require(
            try context.fetch(FetchDescriptor<LiveStream>()).first { $0.name == "News One" }
        )
        context.delete(stream)
        try context.save()
    }

    private func hasNewsOne(in container: ModelContainer) throws -> Bool {
        try ModelContext(container)
            .fetch(FetchDescriptor<LiveStream>())
            .contains { $0.name == "News One" }
    }

    // MARK: - Tests

    @Test func `an unchanged playlist file skips the import`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(playlist, ext: "m3u")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let entry = try makePlaylist(container: container, fileURL: fileURL)
        let playlistId = entry.id
        defer { clearDefaults(playlistId: playlistId) }

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(entry)
        #expect(M3UDigestStore.digest(playlistId: playlistId) != nil, "A completed import must be fingerprinted")

        try deleteNewsOne(in: container)
        try await manager.syncPlaylist(entry)

        #expect(try hasNewsOne(in: container) == false, "An unchanged file must skip the import entirely")
        // The sweeps are skipped with it: nothing the file still names is
        // touched, and nothing it dropped is collected.
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Movie>()) == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Episode>()) == 1)
    }

    @Test func `a changed playlist file is imported again`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(playlist, ext: "m3u")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let entry = try makePlaylist(container: container, fileURL: fileURL)
        let playlistId = entry.id
        defer { clearDefaults(playlistId: playlistId) }

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(entry)

        try deleteNewsOne(in: container)
        try extendedPlaylist.write(to: fileURL, atomically: true, encoding: .utf8)
        try await manager.syncPlaylist(entry)

        #expect(try hasNewsOne(in: container), "A changed file must import")
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LiveStream>()) == 3)
    }

    @Test func `an absent digest imports`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(playlist, ext: "m3u")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let entry = try makePlaylist(container: container, fileURL: fileURL)
        let playlistId = entry.id
        defer { clearDefaults(playlistId: playlistId) }

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(entry)

        // What a fresh install, or a second device, sees: same file, no record
        // of ever having imported it.
        M3UDigestStore.remove(playlistId: playlistId)
        try deleteNewsOne(in: container)
        try await manager.syncPlaylist(entry)

        #expect(try hasNewsOne(in: container), "Without a stored digest the import must run")
    }

    @Test func `a skipped sync still advances the playlist dates`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(playlist, ext: "m3u")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let entry = try makePlaylist(container: container, fileURL: fileURL)
        let playlistId = entry.id
        defer { clearDefaults(playlistId: playlistId) }

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(entry)

        let backdated = Date.distantPast
        do {
            let context = ModelContext(container)
            let stored = try #require(
                try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })).first
            )
            stored.lastUpdated = backdated
            stored.lastSyncDate = backdated
            try context.save()
        }

        try await manager.syncPlaylist(entry)

        let context = ModelContext(container)
        let stored = try #require(
            try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })).first
        )
        #expect(stored.lastUpdated ?? backdated > backdated, "A skipped sync did succeed — lastUpdated must advance")
        #expect(stored.lastSyncDate ?? backdated > backdated, "A skipped sync did succeed — lastSyncDate must advance")
    }

    @Test func `a skipped sync still re-adopts the playlist's url-tvg header`() async throws {
        let container = try makeTestContainer()
        // The header carries a guide URL; the entries are the same either way.
        let withHeader = playlist.replacingOccurrences(
            of: "#EXTM3U",
            with: #"#EXTM3U url-tvg="http://example.com/embedded-guide.xml""#
        )
        let fileURL = try writeTempFile(withHeader, ext: "m3u")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlistModel = try makePlaylist(container: container, fileURL: fileURL)
        let playlistId = playlistModel.id
        defer { clearDefaults(playlistId: playlistId) }

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(playlistModel)

        // The user clears their guide URL between syncs.
        do {
            let context = ModelContext(container)
            let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
            stored.epgURL = nil
            try context.save()
        }
        // Removed behind the sync's back: a skipped import leaves the hole, an
        // import that actually ran would fill it back in. That is what proves
        // the assertion below is about the skip path and not a re-import.
        try deleteNewsOne(in: container)

        // Same bytes, so the import is skipped — but the header still has to be
        // read, or clearing the guide URL would strand the playlist without one
        // until the provider's file happens to change.
        try await manager.syncPlaylist(playlistModel)

        #expect(try !hasNewsOne(in: container), "Sanity: the import really was skipped, not re-run")
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.epgURL == "http://example.com/embedded-guide.xml")
    }
}

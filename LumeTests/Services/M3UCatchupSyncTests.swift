//
//  M3UCatchupSyncTests.swift
//  LumeTests
//
//  End-to-end tests for the catch-up half of the m3u import: a local playlist
//  carrying `catchup` attributes is synced through the real
//  ContentSyncManager into an in-memory store. Split from M3USyncTests.swift,
//  which sits against SwiftLint's file-length limit.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct M3UCatchupSyncTests {
    /// The m3u digest is device-local `UserDefaults` state that outlives a
    /// test, so each case starts from a clean slate rather than inheriting a
    /// sibling's fingerprint.
    init() {
        clearM3UDigests()
    }

    // MARK: - Fixtures

    private func writeTempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m3u")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makePlaylist(container: ModelContainer, fileURL: URL) throws -> Playlist {
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test M3U", m3uURL: fileURL.absoluteString)
        context.insert(playlist)
        try context.save()
        return playlist
    }

    private func catalogStreams(in container: ModelContainer) throws -> [LiveStream] {
        try ModelContext(container).fetch(FetchDescriptor<LiveStream>())
    }

    /// A Flussonic channel with a template and a depth, an `fs` alias with no
    /// depth, and a channel that declares no archive at all.
    private let archivePlaylist = """
    #EXTM3U
    #EXTINF:-1 tvg-id="news.1" catchup="flussonic" catchup-days="7" \
    catchup-source="http://example.com/live/news1.ts?utc={utc}&lutc={now}" group-title="News",News One
    http://example.com/live/news1.ts
    #EXTINF:-1 tvg-id="sport.1" catchup="fs" group-title="Sports",Sport One
    http://example.com/live/sport1.m3u8
    #EXTINF:-1 group-title="General",Ungrouped Extras
    http://example.com/live/extra
    """

    /// `archivePlaylist`'s two archive channels with every catch-up attribute
    /// stripped, on the same URLs — so a re-sync updates those rows instead of
    /// pruning and re-inserting them.
    private let archivelessPlaylist = """
    #EXTM3U
    #EXTINF:-1 tvg-id="news.1" group-title="News",News One
    http://example.com/live/news1.ts
    #EXTINF:-1 tvg-id="sport.1" group-title="Sports",Sport One
    http://example.com/live/sport1.m3u8
    """

    /// Channels that declare an archive we cannot build a URL for, next to one
    /// we can.
    private let unbuildablePlaylist = """
    #EXTM3U
    #EXTINF:-1 catchup="quantum" catchup-days="5" group-title="News",Unknown Scheme
    http://example.com/live/unknown.ts
    #EXTINF:-1 catchup="default" catchup-days="5" group-title="News",No Source
    http://example.com/live/nosource.ts
    #EXTINF:-1 catchup="shift" catchup-source="http://example.com/live/shift.ts?utc={utc}&dur={duration}" group-title="News",Shift Source
    http://example.com/live/shift.ts
    """

    // MARK: - Tests

    @Test func `imports the catch-up columns a playlist declares`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(archivePlaylist)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)

        try await ContentSyncManager(modelContainer: container).syncPlaylist(playlist)

        let streams = try catalogStreams(in: container)
        let newsOne = try #require(streams.first { $0.name == "News One" })
        #expect(newsOne.tvArchive == 1)
        #expect(newsOne.tvArchiveDuration == 7)
        #expect(newsOne.catchupType == .flussonic)
        // Stored verbatim: the placeholders are expanded at play time, so a
        // template baked in here would carry a stale `now` forever.
        #expect(newsOne.catchupSource == "http://example.com/live/news1.ts?utc={utc}&lutc={now}")

        let sportOne = try #require(streams.first { $0.name == "Sport One" })
        #expect(sportOne.tvArchive == 1)
        #expect(sportOne.catchupType == .flussonic, "`fs` is the Flussonic alias")
        #expect(sportOne.tvArchiveDuration == 0, "no declared depth stays 0 rather than an invented day count")

        let ungrouped = try #require(streams.first { $0.name == "Ungrouped Extras" })
        #expect(ungrouped.tvArchive == 0)
        #expect(ungrouped.catchupTypeRaw == nil)
        #expect(ungrouped.catchupSource == nil)
    }

    /// The catch-up columns are dirty-checked like every other m3u field: an
    /// unconditional assignment would mark every archive channel dirty — and
    /// rewrite it — on every re-sync of an unchanged playlist.
    @Test func `a byte-identical re-import leaves catch-up rows clean`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(archivePlaylist)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)

        let manager = ContentSyncManager(modelContainer: container)
        let recorder = CatalogWriteRecorder()
        try await manager.syncPlaylist(playlist)

        let store = try #require(try catalogStreams(in: container).first?.persistentModelID.storeIdentifier)
        #expect(recorder.catalogWrites(inStore: store) > 0, "The first import must write the catalog")

        recorder.reset()
        // Clear the fingerprint so the re-import actually runs rather than
        // being skipped — a skip would pass this vacuously.
        M3UDigestStore.remove(playlistId: playlist.id)
        try await manager.syncPlaylist(playlist)

        #expect(recorder.catalogWrites(inStore: store) == 0, "Re-applying identical catch-up values must not dirty a row")
        let newsOne = try #require(try catalogStreams(in: container).first { $0.name == "News One" })
        #expect(newsOne.tvArchive == 1)
        #expect(newsOne.tvArchiveDuration == 7)
    }

    @Test func `re-sync clears catch-up the provider stops advertising`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(archivePlaylist)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(playlist)

        do {
            let context = ModelContext(container)
            let stream = try #require(try context.fetch(FetchDescriptor<LiveStream>()).first { $0.name == "News One" })
            #expect(stream.tvArchive == 1)
            stream.isFavorite = true
            try context.save()
        }

        try archivelessPlaylist.write(to: fileURL, atomically: true, encoding: .utf8)
        try await manager.syncPlaylist(playlist)

        let stream = try #require(try catalogStreams(in: container).first { $0.name == "News One" })
        #expect(stream.isFavorite, "The favorite proves this is the same row, not a re-insert")
        #expect(stream.tvArchive == 0)
        #expect(stream.tvArchiveDuration == 0)
        #expect(stream.catchupTypeRaw == nil)
        #expect(stream.catchupSource == nil)
    }

    @Test func `an archive we cannot build a URL for is never badged`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(unbuildablePlaylist)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)

        try await ContentSyncManager(modelContainer: container).syncPlaylist(playlist)

        let streams = try catalogStreams(in: container)

        let unknown = try #require(streams.first { $0.name == "Unknown Scheme" })
        #expect(unknown.tvArchive == 0, "An unrecognised dialect must not light up a dead affordance")
        #expect(unknown.tvArchiveDuration == 0)
        #expect(unknown.catchupTypeRaw == nil)

        let noSource = try #require(streams.first { $0.name == "No Source" })
        #expect(noSource.tvArchive == 0, "`default` without a catchup-source has nothing to expand")
        #expect(noSource.tvArchiveDuration == 0, "The declared day count is dropped with the unbuildable scheme")
        #expect(noSource.catchupTypeRaw == nil)

        let shift = try #require(streams.first { $0.name == "Shift Source" })
        #expect(shift.tvArchive == 1)
        #expect(shift.catchupType == .shift)
        #expect(shift.catchupSource == "http://example.com/live/shift.ts?utc={utc}&dur={duration}")
    }
}

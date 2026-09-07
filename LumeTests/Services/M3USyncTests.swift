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

        // Force the second sync down the real import path. The file is
        // byte-identical, so the digest skip would otherwise return before
        // `importM3UFile` and this test would assert nothing about the upsert —
        // which is the thing it exists to pin. The skip has its own coverage in
        // `M3UDigestSkipTests`.
        M3UDigestStore.remove(playlistId: playlist.id)
        try await manager.syncPlaylist(playlist)
        defer { M3UDigestStore.remove(playlistId: playlist.id) }

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

    @Test func `a byte-identical re-import writes no catalog rows`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(mixedPlaylist, ext: "m3u")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)

        let manager = ContentSyncManager(modelContainer: container)
        let recorder = CatalogWriteRecorder()
        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)
        let store = try #require(
            try context.fetch(FetchDescriptor<LiveStream>()).first?.persistentModelID.storeIdentifier
        )
        // Also proves the recorder sees this store at all, so the assertion
        // below can't pass by observing nothing.
        #expect(recorder.catalogWrites(inStore: store) > 0, "The first import must write the catalog")

        recorder.reset()
        // Clear the fingerprint so the re-import actually runs. Without this the
        // digest skip returns before `importM3UFile` and the write count would
        // be zero because nothing executed, not because the dirty check held —
        // the assertion below would pass vacuously. `M3UDigestSkipTests` covers
        // the skip itself.
        M3UDigestStore.remove(playlistId: playlist.id)
        try await manager.syncPlaylist(playlist)
        defer { M3UDigestStore.remove(playlistId: playlist.id) }

        #expect(
            recorder.catalogWrites(inStore: store) == 0,
            "A byte-identical re-import must leave every batch context clean, so no save runs"
        )
        #expect(try context.fetchCount(FetchDescriptor<LiveStream>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<Lume.Category>()) == 6)
    }

    /// A reduced version of `mixedPlaylist`: Sport One (live), The Godfather
    /// (movie) and the whole Breaking Bad series are gone, taking the Sports,
    /// VOD | Drama and Series | Crime categories with them.
    private let reducedPlaylist = """
    #EXTM3U url-tvg="http://example.com/embedded-guide.xml"
    #EXTINF:-1 tvg-id="news.1" tvg-logo="http://example.com/news1.png" group-title="News",News One
    http://example.com/live/news1.ts
    #EXTINF:-1 group-title="General",Ungrouped Extras
    http://example.com/live/extra
    #EXTINF:-1 tvg-logo="http://example.com/film.png" group-title="VOD | Action",Die Hard
    http://example.com/movie/u/p/1001.mp4
    """

    @Test func `re-sync prunes content the playlist no longer contains`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(mixedPlaylist, ext: "m3u")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(playlist)

        // Favorite a survivor to prove pruning leaves untouched rows (and their
        // user state) alone.
        do {
            let context = ModelContext(container)
            let dieHard = try #require(try context.fetch(FetchDescriptor<Movie>()).first { $0.name == "Die Hard" })
            dieHard.isFavorite = true
            try context.save()
        }

        // The provider drops several items; re-sync reads the shrunken file.
        try reducedPlaylist.write(to: fileURL, atomically: true, encoding: .utf8)
        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<LiveStream>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 1)

        // The series section vanished entirely, which is also what a download
        // cut before it looks like — the sanity gate holds those rows back for a
        // bounded number of syncs rather than deleting them on the strength of a
        // file that may simply be short.
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 3)
        // News, General, VOD | Action, and the held-back Series | Crime.
        #expect(try context.fetchCount(FetchDescriptor<Lume.Category>()) == 4)

        #expect(try context.fetch(FetchDescriptor<LiveStream>()).contains { $0.name == "Sport One" } == false)
        #expect(try context.fetch(FetchDescriptor<Movie>()).contains { $0.name == "The Godfather" } == false)
        let categoryNames = try Set(context.fetch(FetchDescriptor<Lume.Category>()).map(\.name))
        #expect(!categoryNames.contains("Sports"))

        // The surviving favorited movie is untouched.
        let dieHard = try #require(try context.fetch(FetchDescriptor<Movie>()).first)
        #expect(dieHard.name == "Die Hard")
        #expect(dieHard.isFavorite, "Pruning must not disturb surviving rows")
    }

    @Test func `a section the provider dropped entirely is swept once the gate relents`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(mixedPlaylist, ext: "m3u")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(playlist)

        // A truncated download does not repeat; a provider that really dropped
        // its series section sends the same short file every sync, so the gate's
        // bounded tolerance has to converge or the rows strand forever.
        try reducedPlaylist.write(to: fileURL, atomically: true, encoding: .utf8)
        for _ in 0 ..< 3 {
            try await manager.syncPlaylist(playlist)
        }

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 0)
        let categoryNames = try Set(context.fetch(FetchDescriptor<Lume.Category>()).map(\.name))
        #expect(!categoryNames.contains("Series | Crime"))
    }

    @Test func `an empty fetch does not prune existing content`() async throws {
        let container = try makeTestContainer()
        let fileURL = try writeTempFile(mixedPlaylist, ext: "m3u")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(playlist)

        // A transient failure looks like an empty file: header only, no entries.
        // The guard must keep the catalog rather than wipe it.
        try "#EXTM3U\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<LiveStream>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<Lume.Category>()) == 6)
    }

    @Test func `dedicated EPG sync imports listings for a playlist's source`() async throws {
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

        // Adding a playlist sets up its EPG source — the guide is no longer
        // fetched as part of the content sync.
        let setupContext = ModelContext(container)
        if let stored = try setupContext.fetch(FetchDescriptor<Playlist>()).first {
            EPGSourceReconciler.reconcile(stored, in: setupContext)
        }
        #expect(try setupContext.fetchCount(FetchDescriptor<EPGSource>()) == 1)

        // Content sync brings in the channels the guide is matched against, but
        // imports no EPG itself.
        try await ContentSyncManager(modelContainer: container).syncPlaylist(playlist)
        #expect(try setupContext.fetchCount(FetchDescriptor<EPGListing>()) == 0)

        // The dedicated EPG sync imports the guide, filtered to known channels.
        let didSync = await EPGSyncManager(modelContainer: container).syncAllSources()
        #expect(didSync)

        let context = ModelContext(container)
        let listings = try context.fetch(FetchDescriptor<EPGListing>())
        #expect(listings.count == 1, "Only programmes for known tvg-ids are imported")
        #expect(listings.first?.title == "Midday News")
        #expect(listings.first?.channelId == "news.1")
    }

    // MARK: - Cancellation

    /// Cancelling a running sync has to stop the import *and* skip the sweeps:
    /// the seen-ids only cover the part of the file that was read, so sweeping
    /// on them would delete the rest of the catalog — and the iCloud reconcile
    /// that follows every completed sync would push those deletes to every
    /// device. What was already committed stays; the playlist goes back to idle
    /// so the next attempt is a plain retry.
    @Test func `cancelling mid-import stops the pipeline and prunes nothing`() async throws {
        let entryCount = 40000
        var content = "#EXTM3U\n"
        content.reserveCapacity(4_000_000)
        for index in 0 ..< entryCount {
            content += "#EXTINF:-1 tvg-id=\"chan.\(index)\" group-title=\"Group \(index % 10)\",Channel \(index)\n"
            content += "http://example.com/live/\(index).ts\n"
        }

        let container = try makeTestContainer()
        let fileURL = try writeTempFile(content, ext: "m3u")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)
        let playlistId = playlist.id

        // Rows this playlist file does not contain, so a sweep would delete
        // them: their survival is the evidence that no sweep ran.
        let staleCount = 20
        do {
            let context = ModelContext(container)
            for index in 0 ..< staleCount {
                context.insert(LiveStream(
                    id: "\(playlistId.uuidString)-live-stale\(index)",
                    streamId: 900_000 + index,
                    name: "Dropped \(index)"
                ))
            }
            try context.save()
        }

        let manager = ContentSyncManager(modelContainer: container)
        let sync = Task { try await manager.syncPlaylist(playlist) }

        // Cancel once the first batch has committed, so the cancel lands with
        // the file only partly imported.
        var committed = staleCount
        let deadline = ContinuousClock.now + .seconds(60)
        while committed <= staleCount, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
            committed = try ModelContext(container).fetchCount(FetchDescriptor<LiveStream>())
        }
        sync.cancel()
        #expect(committed > staleCount, "no batch committed before the cancel, so the run proves nothing")

        // Surfaced as a cancellation, not buried as SyncError.databaseError.
        await #expect(throws: CancellationError.self) { try await sync.value }

        let context = ModelContext(container)
        let live = try context.fetchCount(FetchDescriptor<LiveStream>())
        #expect(live < entryCount + staleCount, "the import kept importing past the cancellation")
        #expect(live > staleCount, "the batches already committed must survive a cancellation")
        let survivors = try context.fetch(FetchDescriptor<LiveStream>()).count { $0.name.hasPrefix("Dropped ") }
        #expect(survivors == staleCount, "a cancelled import must not sweep")

        let reloaded = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(reloaded.syncStatus == .idle, "an aborted sync leaves the playlist retryable, not in .error")
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

    /// The 100k test above is live and movie rows only, but ~86% of a real
    /// provider file is episodes, and that path does strictly more per entry:
    /// a regex match to classify, a `Series` upsert, and an `Episode` hanging
    /// off it. A regression there would not move the numbers above at all.
    ///
    /// Show names carry the provider's shape ("Show Name (2012) S01 E05") and
    /// the per-show episode counts are deliberately uneven with a long tail —
    /// the real file's median show is 12 episodes and its largest is 2,799,
    /// so a fixture of uniform shows would miss how the per-series work scales.
    @Test func `syncs an episode-heavy playlist in bounded time`() async throws {
        // Most shows run one or two seasons; a few carry hundreds.
        let commonCounts = [3, 6, 8, 10, 12, 12, 13, 16, 20, 26]
        func episodeCount(forShow index: Int) -> Int {
            if index % 499 == 0 { return 600 }
            if index % 97 == 0 { return 180 }
            return commonCounts[index % commonCounts.count]
        }

        let showCount = 3000
        var content = "#EXTM3U\n"
        content.reserveCapacity(8_000_000)
        var episodeTotal = 0
        for show in 0 ..< showCount {
            let showName = "Show \(show) (20\(10 + show % 15))"
            let group = "Series | Genre \(show % 40)"
            for episode in 0 ..< episodeCount(forShow: show) {
                let season = 1 + episode / 24
                let number = 1 + episode % 24
                let token = String(format: "S%02d E%02d", season, number)
                content += "#EXTINF:-1 group-title=\"\(group)\","
                content += "\(showName) \(token)\n"
                content += "http://example.com/series/u/p/\(show)-\(episode).mkv\n"
                episodeTotal += 1
            }
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
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == episodeTotal)
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == showCount)
        #expect(try context.fetchCount(FetchDescriptor<LiveStream>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Lume.Category>()) == 40)

        let seconds = elapsed.components.seconds
        #expect(seconds < 120, "\(episodeTotal)-episode sync took \(seconds)s — expected < 120s")
    }
}

/// Counts the catalog rows the `ModelContext` saves in one store touch.
///
/// The dirty check's payoff is the `save()` `importBatch` never runs, and a row
/// carries no timestamp to observe that by, so the save notification is the only
/// evidence. `Playlist` is excluded: its sync status and `lastSyncDate` are
/// rewritten by every sync by design. Suites run in parallel against their own
/// in-memory stores, hence the store filter.
private final class CatalogWriteRecorder: @unchecked Sendable {
    private static let catalogEntities: Set<String> = [
        "LiveStream", "Movie", "Series", "Episode", "Category"
    ]

    private let lock = NSLock()
    private var written: [PersistentIdentifier] = []
    private var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.record(notification)
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func reset() {
        lock.lock()
        written.removeAll()
        lock.unlock()
    }

    func catalogWrites(inStore store: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return written.count(where: { $0.storeIdentifier == store && Self.catalogEntities.contains($0.entityName) })
    }

    /// Saves post from whichever thread committed them, so the buffer is locked.
    private func record(_ notification: Notification) {
        let keys: [ModelContext.NotificationKey] = [
            .insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers
        ]
        let touched = keys.flatMap { key -> [PersistentIdentifier] in
            let value = notification.userInfo?[key.rawValue]
            if let identifiers = value as? Set<PersistentIdentifier> { return Array(identifiers) }
            return value as? [PersistentIdentifier] ?? []
        }
        guard !touched.isEmpty else { return }
        lock.lock()
        written.append(contentsOf: touched)
        lock.unlock()
    }
}

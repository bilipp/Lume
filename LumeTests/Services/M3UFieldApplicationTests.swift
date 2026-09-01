//
//  M3UFieldApplicationTests.swift
//  LumeTests
//
//  Guards the dirty-checked m3u field application for live streams and movies:
//  an unchanged re-sync must leave the context clean — that is what lets
//  `importBatch` skip the save — while every real provider change, including
//  nil ⇄ "", must still be written. Also pins the m3u-only `num` rule: assigned
//  on insert, never re-assigned afterwards.
//
//  Series and episodes are covered separately; split by model kind to stay
//  under SwiftLint's type-body and file-length limits.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

enum M3UFieldFixtures {
    /// The importer takes the parser's value type, not a provider DTO, so every
    /// fixture is one `#EXTINF` line as the parser would have handed it over.
    static func entry(
        name: String = "BBC One HD",
        url: String = "http://provider.example.com/live/9876",
        tvgId: String? = "bbc.one.uk",
        logo: String? = "http://provider.example.com/logos/bbc1.png",
        group: String? = "News",
        type: String? = nil
    ) -> M3UEntry {
        M3UEntry(name: name, url: url, tvgId: tvgId, logo: logo, group: group, type: type)
    }

    static func movieEntry(
        name: String = "Die Hard",
        url: String = "http://provider.example.com/movie/u/p/1001.mkv",
        logo: String? = "http://provider.example.com/covers/diehard.png",
        group: String? = "VOD | Action"
    ) -> M3UEntry {
        M3UEntry(name: name, url: url, tvgId: nil, logo: logo, group: group, type: nil)
    }

    static func writeTempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m3u")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func makePlaylist(container: ModelContainer, fileURL: URL) throws -> Playlist {
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test M3U", m3uURL: fileURL.absoluteString)
        context.insert(playlist)
        try context.save()
        return playlist
    }
}

// MARK: - Live streams

struct M3ULiveStreamFieldTests {
    /// Swift Testing runs this before every test in the suite. The m3u digest is
    /// device-local `UserDefaults` state that outlives a test, so each case
    /// starts from a clean slate rather than inheriting a sibling's fingerprint.
    init() {
        clearM3UDigests()
    }

    private static let category = "\(UUID().uuidString)-live-News"
    private static let otherCategory = "\(UUID().uuidString)-live-Sports"

    /// Stores `stored` through one context, then re-applies `next` through a
    /// *fresh* one — every import batch builds its own — and reports whether
    /// that second application dirtied it.
    private func reapply(
        stored: M3UEntry,
        storedCategoryId: String,
        next: M3UEntry,
        nextCategoryId: String
    ) async throws -> (dirty: Bool, stream: LiveStream) {
        let container = try makeTestContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let streamId = "live-row"

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = LiveStream(id: streamId, streamId: 1, name: "")
        firstSync.insert(inserted)
        await manager.applyM3ULiveStreamFields(from: stored, to: inserted, categoryId: storedCategoryId)
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let row = try #require(try reSync.fetch(
            FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == streamId })
        ).first)
        await manager.applyM3ULiveStreamFields(from: next, to: row, categoryId: nextCategoryId)
        return (reSync.hasChanges, row)
    }

    @Test func `changed live stream fields are written`() async throws {
        let container = try makeTestContainer()
        let manager = ContentSyncManager(modelContainer: container)

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let stream = LiveStream(id: "live-row", streamId: 1, name: "Stale name")
        stream.categoryId = Self.otherCategory
        context.insert(stream)
        try context.save()

        await manager.applyM3ULiveStreamFields(
            from: M3UFieldFixtures.entry(),
            to: stream,
            categoryId: Self.category
        )

        #expect(context.hasChanges, "A changed entry must dirty the context")
        #expect(stream.name == "BBC One HD")
        #expect(stream.streamIcon == "http://provider.example.com/logos/bbc1.png")
        #expect(stream.epgChannelId == "bbc.one.uk")
        #expect(stream.directURL == "http://provider.example.com/live/9876")
        #expect(stream.categoryId == Self.category)
    }

    @Test func `unchanged live stream entry leaves the context clean`() async throws {
        let entry = M3UFieldFixtures.entry()
        let result = try await reapply(
            stored: entry,
            storedCategoryId: Self.category,
            next: entry,
            nextCategoryId: Self.category
        )

        #expect(!result.dirty, "An unchanged entry must not dirty the context — the save is then skipped")
        #expect(result.stream.name == "BBC One HD")
        #expect(result.stream.epgChannelId == "bbc.one.uk")
    }

    @Test func `each changed live stream field dirties the context`() async throws {
        let base = M3UFieldFixtures.entry()
        var renamed = base
        renamed.name = "BBC Two HD"
        var reLogoed = base
        reLogoed.logo = "http://provider.example.com/logos/bbc2.png"
        var reTagged = base
        reTagged.tvgId = "bbc.two.uk"
        var reURLed = base
        reURLed.url = "http://provider.example.com/live/9877"

        let cases: [(field: String, entry: M3UEntry, categoryId: String)] = [
            ("name", renamed, Self.category),
            ("tvg-logo", reLogoed, Self.category),
            ("tvg-id", reTagged, Self.category),
            ("url", reURLed, Self.category),
            ("group-title", base, Self.otherCategory)
        ]

        for change in cases {
            let result = try await reapply(
                stored: base,
                storedCategoryId: Self.category,
                next: change.entry,
                nextCategoryId: change.categoryId
            )
            #expect(result.dirty, "A changed \(change.field) must be written")
        }
    }

    @Test func `live stream nil and empty attributes are distinct`() async throws {
        let absent = M3UFieldFixtures.entry(tvgId: nil, logo: nil)
        let empty = M3UFieldFixtures.entry(tvgId: "", logo: "")

        let toEmpty = try await reapply(
            stored: absent,
            storedCategoryId: Self.category,
            next: empty,
            nextCategoryId: Self.category
        )
        #expect(toEmpty.dirty, "nil → \"\" is a real change and must be written")
        #expect(toEmpty.stream.streamIcon == "")
        #expect(toEmpty.stream.epgChannelId == "")

        let toNil = try await reapply(
            stored: empty,
            storedCategoryId: Self.category,
            next: absent,
            nextCategoryId: Self.category
        )
        #expect(toNil.dirty, "\"\" → nil is a real change and must be written")
        #expect(toNil.stream.streamIcon == nil)
        #expect(toNil.stream.epgChannelId == nil)

        let unchanged = try await reapply(
            stored: empty,
            storedCategoryId: Self.category,
            next: empty,
            nextCategoryId: Self.category
        )
        #expect(!unchanged.dirty)
    }

    @Test func `a shifted live stream position does not dirty the row`() async throws {
        let container = try makeTestContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let entry = M3UFieldFixtures.entry()
        let streamId = "live-row"

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = LiveStream(id: streamId, streamId: 1, name: "")
        inserted.num = 41
        firstSync.insert(inserted)
        await manager.applyM3ULiveStreamFields(from: entry, to: inserted, categoryId: Self.category)
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == streamId })
        ).first)
        await manager.applyM3ULiveStreamFields(from: entry, to: stored, categoryId: Self.category)

        #expect(stored.num == 41, "num is assigned only on insert")
        #expect(!reSync.hasChanges, "A row that only moved in the file must stay clean")
    }

    @Test func `live stream num is set on insert and kept across a re-sync`() async throws {
        let container = try makeTestContainer()
        let firstFile = """
        #EXTM3U
        #EXTINF:-1 tvg-id="a" group-title="News",Alpha
        http://example.com/live/alpha
        #EXTINF:-1 tvg-id="b" group-title="News",Bravo
        http://example.com/live/bravo
        """
        let fileURL = try M3UFieldFixtures.writeTempFile(firstFile)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try M3UFieldFixtures.makePlaylist(container: container, fileURL: fileURL)

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(playlist)

        let afterFirst = ModelContext(container)
        let alphaNum = try #require(try afterFirst.fetch(FetchDescriptor<LiveStream>())
            .first { $0.name == "Alpha" }?.num)
        let bravoNum = try #require(try afterFirst.fetch(FetchDescriptor<LiveStream>())
            .first { $0.name == "Bravo" }?.num)
        #expect(alphaNum == 0)
        #expect(bravoNum == 1)

        // The provider prepends a channel: every existing row shifts one place
        // down the file, and must keep the num it was inserted with.
        let shiftedFile = """
        #EXTM3U
        #EXTINF:-1 tvg-id="c" group-title="News",Charlie
        http://example.com/live/charlie
        #EXTINF:-1 tvg-id="a" group-title="News",Alpha
        http://example.com/live/alpha
        #EXTINF:-1 tvg-id="b" group-title="News",Bravo
        http://example.com/live/bravo
        """
        try shiftedFile.write(to: fileURL, atomically: true, encoding: .utf8)
        try await manager.syncPlaylist(playlist)

        let afterSecond = ModelContext(container)
        let streams = try afterSecond.fetch(FetchDescriptor<LiveStream>())
        #expect(streams.count == 3)
        #expect(streams.first { $0.name == "Alpha" }?.num == alphaNum)
        #expect(streams.first { $0.name == "Bravo" }?.num == bravoNum)
        #expect(
            streams.first { $0.name == "Charlie" }?.num == 2,
            "A newly inserted row continues the sequence past the stored maximum, rather than taking its file position"
        )
        #expect(
            Set(streams.map(\.num)).count == streams.count,
            "num must stay unique — a duplicate leaves Playlist order to break the tie arbitrarily"
        )
    }
}

// MARK: - Movies

struct M3UMovieFieldTests {
    /// Swift Testing runs this before every test in the suite. The m3u digest is
    /// device-local `UserDefaults` state that outlives a test, so each case
    /// starts from a clean slate rather than inheriting a sibling's fingerprint.
    init() {
        clearM3UDigests()
    }

    private static let category = "\(UUID().uuidString)-vod-VOD | Action"
    private static let otherCategory = "\(UUID().uuidString)-vod-VOD | Drama"

    private func reapply(
        stored: M3UEntry,
        storedCategoryId: String,
        next: M3UEntry,
        nextCategoryId: String
    ) async throws -> (dirty: Bool, movie: Movie) {
        let container = try makeTestContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let movieId = "movie-row"

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Movie(id: movieId, streamId: 1, name: "")
        firstSync.insert(inserted)
        await manager.applyM3UMovieFields(from: stored, to: inserted, categoryId: storedCategoryId)
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let row = try #require(try reSync.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        ).first)
        await manager.applyM3UMovieFields(from: next, to: row, categoryId: nextCategoryId)
        return (reSync.hasChanges, row)
    }

    @Test func `changed movie fields are written`() async throws {
        let container = try makeTestContainer()
        let manager = ContentSyncManager(modelContainer: container)

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let movie = Movie(id: "movie-row", streamId: 1, name: "Stale name")
        movie.categoryId = Self.otherCategory
        context.insert(movie)
        try context.save()

        await manager.applyM3UMovieFields(
            from: M3UFieldFixtures.movieEntry(),
            to: movie,
            categoryId: Self.category
        )

        #expect(context.hasChanges, "A changed entry must dirty the context")
        #expect(movie.name == "Die Hard")
        #expect(movie.streamIcon == "http://provider.example.com/covers/diehard.png")
        #expect(movie.directURL == "http://provider.example.com/movie/u/p/1001.mkv")
        #expect(movie.containerExtension == "mkv")
        #expect(movie.categoryId == Self.category)
    }

    @Test func `unchanged movie entry leaves the context clean`() async throws {
        let entry = M3UFieldFixtures.movieEntry()
        let result = try await reapply(
            stored: entry,
            storedCategoryId: Self.category,
            next: entry,
            nextCategoryId: Self.category
        )

        #expect(!result.dirty, "An unchanged entry must not dirty the context — the save is then skipped")
        #expect(result.movie.name == "Die Hard")
        #expect(result.movie.containerExtension == "mkv")
    }

    @Test func `each changed movie field dirties the context`() async throws {
        let base = M3UFieldFixtures.movieEntry()
        var renamed = base
        renamed.name = "Die Hard 2"
        var reLogoed = base
        reLogoed.logo = "http://provider.example.com/covers/diehard2.png"
        var reURLed = base
        reURLed.url = "http://provider.example.com/movie/u/p/1002.mkv"
        var reContainered = base
        reContainered.url = "http://provider.example.com/movie/u/p/1001.mp4"

        let cases: [(field: String, entry: M3UEntry, categoryId: String)] = [
            ("name", renamed, Self.category),
            ("tvg-logo", reLogoed, Self.category),
            ("url", reURLed, Self.category),
            ("container extension", reContainered, Self.category),
            ("group-title", base, Self.otherCategory)
        ]

        for change in cases {
            let result = try await reapply(
                stored: base,
                storedCategoryId: Self.category,
                next: change.entry,
                nextCategoryId: change.categoryId
            )
            #expect(result.dirty, "A changed \(change.field) must be written")
        }
    }

    @Test func `movie nil and empty attributes are distinct`() async throws {
        let absent = M3UFieldFixtures.movieEntry(logo: nil)
        let empty = M3UFieldFixtures.movieEntry(logo: "")

        let toEmpty = try await reapply(
            stored: absent,
            storedCategoryId: Self.category,
            next: empty,
            nextCategoryId: Self.category
        )
        #expect(toEmpty.dirty, "nil → \"\" is a real change and must be written")
        #expect(toEmpty.movie.streamIcon == "")

        let toNil = try await reapply(
            stored: empty,
            storedCategoryId: Self.category,
            next: absent,
            nextCategoryId: Self.category
        )
        #expect(toNil.dirty, "\"\" → nil is a real change and must be written")
        #expect(toNil.movie.streamIcon == nil)

        let unchanged = try await reapply(
            stored: empty,
            storedCategoryId: Self.category,
            next: empty,
            nextCategoryId: Self.category
        )
        #expect(!unchanged.dirty)
    }

    @Test func `a shifted movie position does not dirty the row`() async throws {
        let container = try makeTestContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let entry = M3UFieldFixtures.movieEntry()
        let movieId = "movie-row"

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Movie(id: movieId, streamId: 1, name: "")
        inserted.num = 137
        firstSync.insert(inserted)
        await manager.applyM3UMovieFields(from: entry, to: inserted, categoryId: Self.category)
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        ).first)
        await manager.applyM3UMovieFields(from: entry, to: stored, categoryId: Self.category)

        #expect(stored.num == 137, "num is assigned only on insert")
        #expect(!reSync.hasChanges, "A row that only moved in the file must stay clean")
    }

    @Test func `movie num is set on insert and kept across a re-sync`() async throws {
        let container = try makeTestContainer()
        let firstFile = """
        #EXTM3U
        #EXTINF:-1 group-title="VOD | Action",Die Hard
        http://example.com/movie/u/p/1001.mkv
        #EXTINF:-1 group-title="VOD | Action",Predator
        http://example.com/movie/u/p/1002.mkv
        """
        let fileURL = try M3UFieldFixtures.writeTempFile(firstFile)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try M3UFieldFixtures.makePlaylist(container: container, fileURL: fileURL)

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(playlist)

        let afterFirst = ModelContext(container)
        let movies = try afterFirst.fetch(FetchDescriptor<Movie>())
        let dieHardNum = try #require(movies.first { $0.name == "Die Hard" }?.num)
        let predatorNum = try #require(movies.first { $0.name == "Predator" }?.num)
        #expect(dieHardNum == 0)
        #expect(predatorNum == 1)

        let shiftedFile = """
        #EXTM3U
        #EXTINF:-1 group-title="VOD | Action",Commando
        http://example.com/movie/u/p/1003.mkv
        #EXTINF:-1 group-title="VOD | Action",Die Hard
        http://example.com/movie/u/p/1001.mkv
        #EXTINF:-1 group-title="VOD | Action",Predator
        http://example.com/movie/u/p/1002.mkv
        """
        try shiftedFile.write(to: fileURL, atomically: true, encoding: .utf8)
        try await manager.syncPlaylist(playlist)

        let afterSecond = ModelContext(container)
        let reSynced = try afterSecond.fetch(FetchDescriptor<Movie>())
        #expect(reSynced.count == 3)
        #expect(reSynced.first { $0.name == "Die Hard" }?.num == dieHardNum)
        #expect(reSynced.first { $0.name == "Predator" }?.num == predatorNum)
        #expect(
            reSynced.first { $0.name == "Commando" }?.num == 2,
            "A newly inserted row continues the sequence past the stored maximum, rather than taking its file position"
        )
        #expect(
            Set(reSynced.map(\.num)).count == reSynced.count,
            "num must stay unique — a duplicate leaves Playlist order to break the tie arbitrarily"
        )
    }
}

//
//  TitleGroupPrimariesTests.swift
//  LumeTests
//
//  Per-category primaries of grouped titles. Runs on a real store file: the
//  recompute fetch matches optional columns with `IN`, which an in-memory store
//  would evaluate in Swift instead of SQL.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct TitleGroupPrimariesTests {
    private static let category = "P-vod-1"

    private func movie(_ id: String, _ name: String, category: String = category, in context: ModelContext) -> Movie {
        let movie = Movie(id: id, streamId: 0, name: name)
        movie.categoryId = category
        movie.titleGroupKey = TitleGroupKey.movie(tmdbId: nil, name: name)
        context.insert(movie)
        return movie
    }

    private func touched(_ rows: [Movie]) -> TitleGroupPrimaries.Touched {
        var touched = TitleGroupPrimaries.Touched()
        touched.movies = Set(rows.compactMap { TitleGroupPrimaries.RowState($0).categoryKey })
        return touched
    }

    @Test func `best quality is the primary of its category`() throws {
        try OnDiskCatalogStore.withContext { context in
            let fhd = movie("a", "Inception (2010) FHD", in: context)
            let uhd = movie("b", "Inception (2010) 4K", in: context)
            let other = movie("c", "Inception (2010) SD", category: "P-vod-2", in: context)
            TitleGroupPrimaries.recompute(categoryKeys: touched([fhd, uhd, other]), in: context, preferredLanguages: [])
            #expect(uhd.isCategoryGroupPrimary)
            #expect(!fhd.isCategoryGroupPrimary)
            #expect(other.isCategoryGroupPrimary, "Another category keeps its own primary")
        }
    }

    @Test func `preferred language breaks a quality tie`() throws {
        try OnDiskCatalogStore.withContext { context in
            let english = movie("a", "EN | Inception (2010) FHD", in: context)
            let german = movie("b", "DE | Inception (2010) FHD", in: context)
            TitleGroupPrimaries.recompute(categoryKeys: touched([english, german]), in: context, preferredLanguages: ["de"])
            #expect(german.isCategoryGroupPrimary)
            #expect(!english.isCategoryGroupPrimary)
        }
    }

    @Test func `equal rank falls to the lowest row id`() throws {
        try OnDiskCatalogStore.withContext { context in
            let later = movie("P-movie-2", "Inception (2010) HD", in: context)
            let earlier = movie("P-movie-1", "Inception (2010) HD", in: context)
            TitleGroupPrimaries.recompute(categoryKeys: touched([later, earlier]), in: context, preferredLanguages: [])
            #expect(earlier.isCategoryGroupPrimary)
            #expect(!later.isCategoryGroupPrimary)
        }
    }

    @Test func `an unchanged election writes nothing`() throws {
        try OnDiskCatalogStore.withContext { context in
            let fhd = movie("a", "Inception (2010) FHD", in: context)
            let uhd = movie("b", "Inception (2010) 4K", in: context)
            TitleGroupPrimaries.recompute(categoryKeys: touched([fhd, uhd]), in: context, preferredLanguages: [])
            try context.save()
            TitleGroupPrimaries.recompute(categoryKeys: touched([fhd, uhd]), in: context, preferredLanguages: [])
            #expect(!context.hasChanges)
        }
    }

    @Test func `rows without a key are never touched`() throws {
        try OnDiskCatalogStore.withContext { context in
            let blank = movie("a", " - ", in: context)
            blank.isCategoryGroupPrimary = false
            #expect(blank.titleGroupKey == nil)
            var keys = Set<TitleGroupPrimaries.CategoryKey>()
            TitleGroupPrimaries.note(
                before: TitleGroupPrimaries.RowState(Movie(id: "x", streamId: 0, name: "")), after: blank, into: &keys
            )
            #expect(keys.isEmpty)
            let keyed = movie("b", "Inception (2010)", in: context)
            TitleGroupPrimaries.recompute(categoryKeys: touched([blank, keyed]), in: context, preferredLanguages: [])
            #expect(!blank.isCategoryGroupPrimary)
            #expect(keyed.isCategoryGroupPrimary)
        }
    }

    @Test func `untouched pairs in the fetched cross product keep their flags`() throws {
        try OnDiskCatalogStore.withContext { context in
            // Touched: (vod-1, Inception) and (vod-2, Dune). The fetch also
            // returns (vod-1, Dune), which nothing touched.
            let inception = movie("a", "Inception (2010)", in: context)
            let dune = movie("d", "Dune (2021)", category: "P-vod-2", in: context)
            let bystander = movie("b", "Dune (2021)", in: context)
            let bystanderSibling = movie("c", "Dune (2021) 4K", in: context)
            bystander.isCategoryGroupPrimary = true
            bystanderSibling.isCategoryGroupPrimary = false
            TitleGroupPrimaries.recompute(categoryKeys: touched([inception, dune]), in: context, preferredLanguages: [])
            #expect(bystander.isCategoryGroupPrimary && !bystanderSibling.isCategoryGroupPrimary)
        }
    }

    @Test func `a deleted primary hands over to its sibling`() throws {
        try OnDiskCatalogStore.withContext { context in
            let fhd = movie("a", "Inception (2010) FHD", in: context)
            let uhd = movie("b", "Inception (2010) 4K", in: context)
            TitleGroupPrimaries.recompute(categoryKeys: touched([fhd, uhd]), in: context, preferredLanguages: [])
            try context.save()
            let gone = touched([uhd])
            context.delete(uhd)
            TitleGroupPrimaries.recompute(categoryKeys: gone, in: context, preferredLanguages: [])
            #expect(fhd.isCategoryGroupPrimary)
        }
    }

    @Test func `series elect independently of movies`() throws {
        try OnDiskCatalogStore.withContext { context in
            let sherlockHD = Series(id: "s1", seriesId: 1, name: "Sherlock HD")
            sherlockHD.categoryId = "P-series-1"
            sherlockHD.titleGroupKey = TitleGroupKey.series(tmdbId: nil, name: sherlockHD.name)
            let sherlockFHD = Series(id: "s2", seriesId: 2, name: "Sherlock FHD")
            sherlockFHD.categoryId = "P-series-1"
            sherlockFHD.titleGroupKey = TitleGroupKey.series(tmdbId: nil, name: sherlockFHD.name)
            context.insert(sherlockHD)
            context.insert(sherlockFHD)
            var touched = TitleGroupPrimaries.Touched()
            touched.series = Set([sherlockHD, sherlockFHD].compactMap { TitleGroupPrimaries.RowState($0).categoryKey })
            TitleGroupPrimaries.recompute(categoryKeys: touched, in: context, preferredLanguages: [])
            #expect(sherlockFHD.isCategoryGroupPrimary && !sherlockHD.isCategoryGroupPrimary)
        }
    }

    @Test func `match key is nil for an empty title`() {
        #expect(TitleGroupKey.matchKey(name: " - ") == nil)
        #expect(TitleGroupKey.matchKey(name: "") == nil)
        #expect(TitleGroupKey.matchKey(name: "Inception (2010) FHD") == "t:inception|2010")
    }

    @Test func `assignKey sets the match key alongside a tmdb group key`() {
        let movie = Movie(id: "m", streamId: 0, name: "The Matrix (1999) 4K")
        movie.tmdbId = 603
        TitleGroupPrimaries.assignKey(to: movie)
        #expect(movie.titleGroupKey == "tmdb:603")
        #expect(movie.titleMatchKey == "t:the matrix|1999")

        let series = Series(id: "s", seriesId: 0, name: "Dark (2017) HD")
        series.tmdbId = 70523
        TitleGroupPrimaries.assignKey(to: series)
        #expect(series.titleGroupKey == "tmdb:70523")
        #expect(series.titleMatchKey == "t:dark|2017")
    }

    @Test func `a row without a match key needs a key`() {
        let movie = Movie(id: "m", streamId: 0, name: "Heat (1995)")
        movie.titleGroupKey = "t:heat|1995"
        #expect(TitleGroupPrimaries.needsKey(movie, previousName: movie.name, previousTmdbId: nil))
        movie.titleMatchKey = "t:heat|1995"
        #expect(!TitleGroupPrimaries.needsKey(movie, previousName: movie.name, previousTmdbId: nil))
    }
}

/// The import writes keys and primaries, and the sweep re-elects after a prune.
struct TitleGroupImportTests {
    init() {
        clearM3UDigests()
    }

    private func playlistFile(_ entries: [(name: String, url: String)]) throws -> URL {
        var text = "#EXTM3U\n"
        for entry in entries {
            text += "#EXTINF:-1 group-title=\"VOD | Movies\",\(entry.name)\n\(entry.url)\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m3u")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func `m3u import groups copies and re-elects after a prune`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = OnDiskCatalogStore.catalogSchema
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema, url: directory.appendingPathComponent("catalog.store"), cloudKitDatabase: .none
            )
        )

        let fileURL = try playlistFile([
            ("Inception (2010) FHD", "http://example.com/vod/inception-fhd.mkv"),
            ("Inception (2010) 4K", "http://example.com/vod/inception-4k.mkv"),
            ("Dune (2021)", "http://example.com/vod/dune.mkv")
        ])
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let setup = ModelContext(container)
        let playlist = Playlist(name: "Grouping", m3uURL: fileURL.absoluteString)
        setup.insert(playlist)
        try setup.save()

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(playlist)

        var movies = try ModelContext(container).fetch(FetchDescriptor<Movie>())
        let fhd = try #require(movies.first { $0.name.hasSuffix("FHD") })
        let uhd = try #require(movies.first { $0.name.hasSuffix("4K") })
        let dune = try #require(movies.first { $0.name.hasPrefix("Dune") })
        #expect(fhd.titleGroupKey == "t:inception|2010" && uhd.titleGroupKey == "t:inception|2010")
        #expect(dune.titleGroupKey == "t:dune|2021")
        #expect(movies.allSatisfy { $0.titleMatchKey == $0.titleGroupKey }, "m3u rows stamp the match key")
        #expect(uhd.isCategoryGroupPrimary && !fhd.isCategoryGroupPrimary && dune.isCategoryGroupPrimary)

        try """
        #EXTM3U
        #EXTINF:-1 group-title="VOD | Movies",Inception (2010) FHD
        http://example.com/vod/inception-fhd.mkv
        #EXTINF:-1 group-title="VOD | Movies",Dune (2021)
        http://example.com/vod/dune.mkv
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        try await manager.syncPlaylist(playlist)

        movies = try ModelContext(container).fetch(FetchDescriptor<Movie>())
        #expect(movies.count == 2)
        let remaining = try #require(movies.first { $0.name.hasSuffix("FHD") })
        #expect(remaining.isCategoryGroupPrimary)
    }

    private func onDiskContainer(in directory: URL) throws -> ModelContainer {
        let schema = OnDiskCatalogStore.catalogSchema
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema, url: directory.appendingPathComponent("catalog.store"), cloudKitDatabase: .none
            )
        )
    }

    private func primaryCounts(in container: ModelContainer) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for movie in try ModelContext(container).fetch(FetchDescriptor<Movie>()) where movie.isCategoryGroupPrimary {
            counts["\(movie.categoryId ?? "")|\(movie.titleGroupKey ?? "")", default: 0] += 1
        }
        return counts
    }

    /// The election runs once after the last batch, so copies written by
    /// different batches still end with one primary.
    @Test func `m3u title split across import batches keeps one primary`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try onDiskContainer(in: directory)

        // Past 2,000 entries (one batch) between the copies.
        var entries: [(name: String, url: String)] = [("Inception (2010) FHD", "http://example.com/vod/inception-fhd.mkv")]
        entries += (0 ..< 2500).map { ("Filler \($0) (1990)", "http://example.com/vod/filler-\($0).mkv") }
        entries.append(("Inception (2010) 4K", "http://example.com/vod/inception-4k.mkv"))
        entries += (2500 ..< 4500).map { ("Filler \($0) (1990)", "http://example.com/vod/filler-\($0).mkv") }
        entries.append(("Inception (2010) SD", "http://example.com/vod/inception-sd.mkv"))
        let fileURL = try playlistFile(entries)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let setup = ModelContext(container)
        let playlist = Playlist(name: "Split", m3uURL: fileURL.absoluteString)
        setup.insert(playlist)
        try setup.save()
        defer { TitleGroupPrimaries.Deferred.clear(playlistId: playlist.id) }

        try await ContentSyncManager(modelContainer: container).syncPlaylist(playlist)

        let movies = try ModelContext(container).fetch(FetchDescriptor<Movie>())
        #expect(movies.count == entries.count)
        let copies = movies.filter { $0.titleGroupKey == "t:inception|2010" }
        #expect(copies.count == 3)
        #expect(copies.filter(\.isCategoryGroupPrimary).map(\.name) == ["Inception (2010) 4K"])
        #expect(try primaryCounts(in: container).values.allSatisfy { $0 == 1 })
        #expect(!UserDefaults.standard.bool(forKey: TitleGroupPrimaries.Deferred.pendingKey(playlistId: playlist.id)))
    }

    /// An import stopped before its election leaves the flag; the next one
    /// re-elects rows its own dirty check no longer reports.
    @Test func `m3u import after an interrupted election converges`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try onDiskContainer(in: directory)

        let fileURL = try playlistFile([
            ("Inception (2010) FHD", "http://example.com/vod/inception-fhd.mkv"),
            ("Inception (2010) 4K", "http://example.com/vod/inception-4k.mkv")
        ])
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let setup = ModelContext(container)
        let playlist = Playlist(name: "Interrupted", m3uURL: fileURL.absoluteString)
        setup.insert(playlist)
        try setup.save()
        defer { TitleGroupPrimaries.Deferred.clear(playlistId: playlist.id) }
        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncPlaylist(playlist)

        // What a stop between the last batch and the election leaves behind.
        let context = ModelContext(container)
        for movie in try context.fetch(FetchDescriptor<Movie>()) {
            movie.isCategoryGroupPrimary = true
        }
        try context.save()
        UserDefaults.standard.set(true, forKey: TitleGroupPrimaries.Deferred.pendingKey(playlistId: playlist.id))

        try """
        #EXTM3U
        #EXTINF:-1 group-title="VOD | Movies",Inception (2010) FHD
        http://example.com/vod/inception-fhd.mkv
        #EXTINF:-1 group-title="VOD | Movies",Inception (2010) 4K
        http://example.com/vod/inception-4k.mkv
        #EXTINF:-1 group-title="VOD | Movies",Dune (2021)
        http://example.com/vod/dune.mkv
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        try await manager.syncPlaylist(playlist)

        let movies = try ModelContext(container).fetch(FetchDescriptor<Movie>())
        let primaries = movies.filter { $0.titleGroupKey == "t:inception|2010" && $0.isCategoryGroupPrimary }
        #expect(primaries.map(\.name) == ["Inception (2010) 4K"])
        #expect(!UserDefaults.standard.bool(forKey: TitleGroupPrimaries.Deferred.pendingKey(playlistId: playlist.id)))
    }

    @Test func `xtream field application derives the key once`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let movie = Movie(id: "P-movie-1", streamId: 1, name: "")
        context.insert(movie)

        let dto = try FieldFixtures.decodeMovie(FieldFixtures.movieJSON(name: "The Matrix", tmdb: "\"603\""))
        await manager.applyMovieFields(from: dto, to: movie, playlistPrefix: "P-vod-")
        #expect(movie.titleGroupKey == "tmdb:603")
        try context.save()

        await manager.applyMovieFields(from: dto, to: movie, playlistPrefix: "P-vod-")
        #expect(!context.hasChanges)

        let untagged = try FieldFixtures.decodeMovie(FieldFixtures.movieJSON(name: "The Matrix (1999)", tmdb: "null"))
        let fresh = Movie(id: "P-movie-2", streamId: 2, name: "")
        context.insert(fresh)
        await manager.applyMovieFields(from: untagged, to: fresh, playlistPrefix: "P-vod-")
        #expect(fresh.titleGroupKey == "t:the matrix|1999")
    }
}

//
//  M3UImportOrderTests.swift
//  LumeTests
//
//  What the m3u import owes the file it read: `num` is the entry's position in
//  that file, and one show named by entries under several group titles still
//  resolves to one `Series` row built from the first of them.
//
//  Its own file rather than more of `M3USyncTests`, which is already against
//  SwiftLint's 600-line file limit.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct M3UImportOrderTests {
    /// The m3u digest is device-local `UserDefaults` state that outlives a
    /// test, so each case starts from a clean slate.
    init() {
        clearM3UDigests()
    }

    // MARK: - Fixtures

    private func sync(_ fileURL: URL) async throws -> (container: ModelContainer, playlistId: UUID) {
        let container = try makeTestContainer()
        let playlist = try M3UFieldFixtures.makePlaylist(container: container, fileURL: fileURL)
        let playlistId = playlist.id
        try await ContentSyncManager(modelContainer: container).syncPlaylist(playlist)
        M3UDigestStore.remove(playlistId: playlistId)
        return (container, playlistId)
    }

    // MARK: - Insert order

    /// `num` is the entry's file position, assigned on first insert only, and is
    /// what "Playlist order" sorts by. The import parses and classifies off the
    /// sync actor now and hands batches to the writer over a channel, so file
    /// order is no longer something the call stack guarantees — it has to come
    /// out of the store exactly as the file went in, and identically on every
    /// run.
    @Test func `num follows file order and is identical across runs`() async throws {
        var content = "#EXTM3U\n"
        content.reserveCapacity(1_000_000)
        // The three kinds interleave, so each kind's counter advances out of
        // step with the file position — a writer that reordered anything would
        // land on different numbers rather than merely different rows.
        var expectedLive: [String: Int] = [:]
        var expectedMovies: [String: Int] = [:]
        var expectedSeries: [String: Int] = [:]
        // Over two full 2,000-entry import batches, so the channel really does
        // carry more than one hand-off.
        for index in 0 ..< 5000 {
            switch index % 5 {
            case 0, 1:
                let name = "Channel \(index)"
                content += "#EXTINF:-1 tvg-id=\"chan.\(index)\" group-title=\"Live \(index % 7)\",\(name)\n"
                content += "http://example.com/live/\(index).ts\n"
                expectedLive[name] = expectedLive.count
            case 2:
                let name = "Movie \(index)"
                content += "#EXTINF:-1 group-title=\"VOD \(index % 5)\",\(name)\n"
                content += "http://example.com/vod/\(index).mp4\n"
                expectedMovies[name] = expectedMovies.count
            default:
                let show = "Show \(index % 60)"
                content += "#EXTINF:-1 group-title=\"Series | Genre \(index % 4)\","
                content += "\(show) S01E\(1000 + index)\n"
                content += "http://example.com/series/u/p/\(index).mkv\n"
                if expectedSeries[show] == nil { expectedSeries[show] = expectedSeries.count }
            }
        }

        let fileURL = try M3UFieldFixtures.writeTempFile(content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        func numbering(_ container: ModelContainer) throws -> (live: [String: Int], movies: [String: Int], series: [String: Int]) {
            let context = ModelContext(container)
            return try (
                Dictionary(uniqueKeysWithValues: context.fetch(FetchDescriptor<LiveStream>()).map { ($0.name, $0.num) }),
                Dictionary(uniqueKeysWithValues: context.fetch(FetchDescriptor<Movie>()).map { ($0.name, $0.num) }),
                Dictionary(uniqueKeysWithValues: context.fetch(FetchDescriptor<Series>()).map { ($0.name, $0.num) })
            )
        }

        let firstRun = try await sync(fileURL)
        let first = try numbering(firstRun.container)
        #expect(first.live == expectedLive, "live num must be the entry's position among live entries")
        #expect(first.movies == expectedMovies, "movie num must be the entry's position among movie entries")
        #expect(first.series == expectedSeries, "series num must be first-sight order, not batch order")

        // A second, independent import of the same file into a fresh store: the
        // numbering is reproducible, not merely internally consistent.
        let secondRun = try await sync(fileURL)
        let second = try numbering(secondRun.container)
        #expect(second.live == first.live)
        #expect(second.movies == first.movies)
        #expect(second.series == first.series)
    }

    // MARK: - Series built from several entries

    /// ~44 shows of ~43.5k in a provider file are named under more than one
    /// group title. One `Series` row results, and once it has artwork the first
    /// entry that supplied it owns its fields — later entries stop being
    /// consulted.
    @Test func `a show spanning two group titles keeps its first entry's fields`() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-logo="http://example.com/first.png" group-title="Series | Crime",Multi Show S01E01 One
        http://example.com/series/u/p/1.mkv
        #EXTINF:-1 tvg-logo="http://example.com/second.png" group-title="Series | Drama",Multi Show S01E02 Two
        http://example.com/series/u/p/2.mkv
        """
        let fileURL = try M3UFieldFixtures.writeTempFile(content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let (container, playlistId) = try await sync(fileURL)
        let context = ModelContext(container)
        let series = try #require(try context.fetch(FetchDescriptor<Series>()).first)
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == 1)
        #expect(series.name == "Multi Show")
        #expect(series.cover == "http://example.com/first.png")
        #expect(series.categoryId == "\(playlistId.uuidString)-series-Series | Crime")
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 2)
    }

    /// The other half of that rule: a show whose first entry carries no
    /// `tvg-logo` keeps consulting later entries until one does, so an early
    /// artwork-less episode can't leave the show blank. The later entry supplies
    /// the group title along with the cover — the two fields are applied
    /// together, and this is what the code has always done.
    @Test func `a show whose first entry has no artwork takes a later entry's cover`() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1 group-title="Series | Crime",Late Art S01E01 One
        http://example.com/series/u/p/1.mkv
        #EXTINF:-1 tvg-logo="http://example.com/late.png" group-title="Series | Drama",Late Art S01E02 Two
        http://example.com/series/u/p/2.mkv
        #EXTINF:-1 tvg-logo="http://example.com/later.png" group-title="Series | Crime",Late Art S01E03 Three
        http://example.com/series/u/p/3.mkv
        """
        let fileURL = try M3UFieldFixtures.writeTempFile(content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let (container, playlistId) = try await sync(fileURL)
        let context = ModelContext(container)
        let series = try #require(try context.fetch(FetchDescriptor<Series>()).first)
        #expect(series.cover == "http://example.com/late.png", "the first entry that has artwork wins")
        #expect(series.categoryId == "\(playlistId.uuidString)-series-Series | Drama")
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 3)
    }
}

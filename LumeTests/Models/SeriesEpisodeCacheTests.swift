//
//  SeriesEpisodeCacheTests.swift
//  LumeTests
//
//  Covers the episode cache behind the series detail screens. Xtream and
//  Stalker episodes are fetched lazily per series and are never swept by
//  playlist sync, so a cached season used to stick forever — a device that had
//  opened a show before the provider added an episode kept showing the short
//  list no matter how often the playlist synced. Sync is now what reopens the
//  question: a bumped `lastModified`, or a playlist that synced past the fetch.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SeriesEpisodeCacheTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Series.self, Episode.self])
        // `cloudKitDatabase: .none`: the catalog uses `@Attribute(.unique)`,
        // which CloudKit forbids and fails the load on a signed test host.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func parsed(season: Int, number: Int) -> ParsedEpisode {
        ParsedEpisode(
            id: "s\(season)e\(number)",
            episodeId: "\(season)-\(number)",
            title: "S\(season)E\(number)",
            containerExtension: "mkv",
            seasonNum: season,
            episodeNum: number,
            added: nil,
            directSource: nil,
            durationSecs: nil,
            movieImage: nil,
            rating: nil,
            airDate: nil,
            plot: nil
        )
    }

    @Test func `a series that never fetched episodes is stale`() {
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        #expect(series.episodesAreStale(lastSyncedAt: nil))
    }

    @Test func `a fresh fetch is not stale`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show", lastModified: "1700000000")
        context.insert(series)

        series.insertEpisodes([parsed(season: 1, number: 1)], into: context)

        #expect(series.episodesFetchedAt != nil)
        // A sync that ran before the fetch settles nothing new.
        #expect(!series.episodesAreStale(lastSyncedAt: Date().addingTimeInterval(-60)))
    }

    @Test func `a bumped provider lastModified invalidates the cache`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show", lastModified: "1700000000")
        context.insert(series)
        series.insertEpisodes([parsed(season: 1, number: 1)], into: context)

        // What a sync does when the provider adds an episode.
        series.lastModified = "1700009999"

        #expect(series.episodesAreStale(lastSyncedAt: nil))
    }

    @Test func `a sync since the fetch invalidates the cache`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // Portals that don't maintain `last_modified` leave it nil forever, so
        // the playlist's own sync date is the only signal left.
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        context.insert(series)
        series.insertEpisodes([parsed(season: 1, number: 1)], into: context)

        #expect(series.episodesAreStale(lastSyncedAt: Date().addingTimeInterval(60)))
    }

    @Test func `a never-synced playlist leaves a fetched list alone`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        context.insert(series)
        series.insertEpisodes([parsed(season: 1, number: 1)], into: context)

        #expect(!series.episodesAreStale(lastSyncedAt: nil))
    }

    @Test func `a refresh merges in the newly added episode`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        context.insert(series)
        series.insertEpisodes([1, 2, 3, 4].map { parsed(season: 1, number: $0) }, into: context)

        // The refresh re-fetches the whole season, now five episodes long.
        series.insertEpisodes([1, 2, 3, 4, 5].map { parsed(season: 1, number: $0) }, into: context)

        #expect(series.episodes.count == 5)
        #expect(series.episodes.count(where: { $0.episodeNum == 5 }) == 1)
    }

    @Test func `a short provider response never drops cached episodes`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        context.insert(series)
        series.insertEpisodes([1, 2, 3, 4, 5].map { parsed(season: 1, number: $0) }, into: context)

        // A hiccuping portal answering with a truncated season must not take
        // watched episodes with it — the merge is additive on purpose.
        series.insertEpisodes([parsed(season: 1, number: 1)], into: context)

        #expect(series.episodes.count == 5)
    }
}

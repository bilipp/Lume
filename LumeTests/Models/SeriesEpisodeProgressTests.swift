//
//  SeriesEpisodeProgressTests.swift
//  LumeTests
//
//  Verifies the single-pass episode derivations behind the series detail
//  screens' Play button: the furthest-progress markers and the next-episode
//  resolution (resume in-progress → successor of furthest watched, wrapping
//  to the premiere after the finale → fallback).
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SeriesEpisodeProgressTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Series.self, Episode.self])
        // `cloudKitDatabase: .none`: the catalog uses `@Attribute(.unique)`,
        // which CloudKit forbids and fails the load on a signed test host.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Two seasons × three episodes, unwatched, inserted out of order to prove
    /// the scans don't depend on relationship order.
    private func seedEpisodes(in context: ModelContext) -> [Episode] {
        var episodes: [Episode] = []
        for (season, number) in [(2, 2), (1, 1), (2, 3), (1, 3), (2, 1), (1, 2)] {
            let episode = Episode(
                id: "s\(season)e\(number)", episodeId: "\(season)-\(number)", title: "S\(season)E\(number)",
                containerExtension: "mkv", seasonNum: season, episodeNum: number
            )
            context.insert(episode)
            episodes.append(episode)
        }
        return episodes
    }

    private func episode(_ episodes: [Episode], _ season: Int, _ number: Int) -> Episode {
        episodes.first { $0.seasonNum == season && $0.episodeNum == number }!
    }

    @Test func `markers are nil for an unwatched series`() throws {
        let container = try makeContainer()
        let episodes = seedEpisodes(in: container.mainContext)

        let markers = SeriesEpisodeProgress.markers(in: episodes)
        #expect(markers.furthestInProgress == nil)
        #expect(markers.furthestAnyProgress == nil)
        #expect(markers.furthestWatched == nil)
    }

    @Test func `markers pick the furthest episode by season then number`() throws {
        let container = try makeContainer()
        let episodes = seedEpisodes(in: container.mainContext)
        episode(episodes, 1, 3).isWatched = true
        episode(episodes, 2, 1).isWatched = true
        episode(episodes, 1, 2).watchProgress = 300 // in-progress, earlier than the watched ones
        episode(episodes, 2, 2).watchProgress = 120 // in-progress, furthest overall

        let markers = SeriesEpisodeProgress.markers(in: episodes)
        #expect(markers.furthestInProgress === episode(episodes, 2, 2))
        #expect(markers.furthestAnyProgress === episode(episodes, 2, 2))
        #expect(markers.furthestWatched === episode(episodes, 2, 1))
    }

    @Test func `next episode resumes the furthest in-progress episode`() throws {
        let container = try makeContainer()
        let episodes = seedEpisodes(in: container.mainContext)
        episode(episodes, 2, 1).isWatched = true
        episode(episodes, 1, 2).watchProgress = 300

        let next = SeriesEpisodeProgress.nextEpisode(in: episodes, fallback: nil)
        #expect(next === episode(episodes, 1, 2))
    }

    @Test func `next episode follows the furthest watched one across seasons`() throws {
        let container = try makeContainer()
        let episodes = seedEpisodes(in: container.mainContext)
        episode(episodes, 1, 3).isWatched = true // season finale → next is S2E1

        let next = SeriesEpisodeProgress.nextEpisode(in: episodes, fallback: nil)
        #expect(next === episode(episodes, 2, 1))
    }

    @Test func `next episode wraps to the premiere after the series finale`() throws {
        let container = try makeContainer()
        let episodes = seedEpisodes(in: container.mainContext)
        episode(episodes, 2, 3).isWatched = true

        let next = SeriesEpisodeProgress.nextEpisode(in: episodes, fallback: nil)
        #expect(next === episode(episodes, 1, 1))
    }

    @Test func `next episode falls back to the given episode, then the premiere`() throws {
        let container = try makeContainer()
        let episodes = seedEpisodes(in: container.mainContext)

        let fallback = episode(episodes, 2, 1)
        #expect(SeriesEpisodeProgress.nextEpisode(in: episodes, fallback: fallback) === fallback)
        #expect(SeriesEpisodeProgress.nextEpisode(in: episodes, fallback: nil) === episode(episodes, 1, 1))
        #expect(SeriesEpisodeProgress.nextEpisode(in: [], fallback: nil) == nil)
    }

    @Test func `a fully watched episode does not count as in-progress`() throws {
        let container = try makeContainer()
        let episodes = seedEpisodes(in: container.mainContext)
        let watched = episode(episodes, 1, 2)
        watched.watchProgress = 2400
        watched.isWatched = true

        let markers = SeriesEpisodeProgress.markers(in: episodes)
        #expect(markers.furthestInProgress == nil)
        #expect(markers.furthestWatched === watched)
        // Resume target is the episode after it, not the watched one itself.
        #expect(SeriesEpisodeProgress.nextEpisode(in: episodes, fallback: nil) === episode(episodes, 1, 3))
    }
}

//
//  NextEpisodeResolverTests.swift
//  LumeTests
//
//  Covers the "play next"/"play previous" resolution behind auto-advance and the
//  in-player episode transport buttons (`NextEpisodeResolver.nextMedia` /
//  `.previousMedia`): season-internal ordering, crossing a season boundary in
//  both directions, the series finale and premiere, and non-episode input.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct NextEpisodeResolverTests {
    /// Builds a series whose id carries the playlist UUID prefix (matching the
    /// scheme `ContentSyncManager` writes and `playlist(for:)` keys off), with
    /// the given `(season, episode)` pairs inserted in a deliberately shuffled
    /// order so the resolver's own sort is what's under test.
    private func makeWorld(
        episodes specs: [(season: Int, episode: Int)]
    ) throws -> (ModelContext, Playlist, Series) {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(
            name: "Test",
            serverURL: "http://example.com:8080",
            username: "user",
            password: "pass"
        )
        context.insert(playlist)

        let series = Series(id: "\(playlist.id.uuidString)-series-1", seriesId: 1, name: "Show")
        context.insert(series)

        for spec in specs {
            let episode = Episode(
                id: episodeID(season: spec.season, episode: spec.episode),
                episodeId: "\(spec.season)\(spec.episode)",
                title: "S\(spec.season)E\(spec.episode)",
                containerExtension: "mkv",
                seasonNum: spec.season,
                episodeNum: spec.episode,
                series: series
            )
            context.insert(episode)
            series.episodes.append(episode)
        }
        try context.save()
        return (context, playlist, series)
    }

    private func episodeID(season: Int, episode: Int) -> String {
        "ep-s\(season)e\(episode)"
    }

    private func ref(season: Int, episode: Int) -> PlayableMedia.ContentRef {
        .episode(episodeID(season: season, episode: episode))
    }

    /// Shuffled on purpose: the resolver must order by (season, episode), not by
    /// insertion order.
    private let twoSeasons: [(season: Int, episode: Int)] = [
        (season: 2, episode: 1),
        (season: 1, episode: 2),
        (season: 1, episode: 1),
        (season: 2, episode: 2)
    ]

    @Test func `next within the same season`() throws {
        let (context, _, _) = try makeWorld(episodes: twoSeasons)
        let next = NextEpisodeResolver.nextMedia(after: ref(season: 1, episode: 1), in: context)
        #expect(next?.contentRef == ref(season: 1, episode: 2))
    }

    @Test func `next crosses the season boundary`() throws {
        // The last episode of season 1 should roll over to the first of season 2.
        let (context, _, _) = try makeWorld(episodes: twoSeasons)
        let next = NextEpisodeResolver.nextMedia(after: ref(season: 1, episode: 2), in: context)
        #expect(next?.contentRef == ref(season: 2, episode: 1))
    }

    @Test func `series finale has no next episode`() throws {
        let (context, _, _) = try makeWorld(episodes: twoSeasons)
        let next = NextEpisodeResolver.nextMedia(after: ref(season: 2, episode: 2), in: context)
        #expect(next == nil)
    }

    @Test func `resolved media carries a playable URL`() throws {
        let (context, _, _) = try makeWorld(episodes: twoSeasons)
        let next = try #require(NextEpisodeResolver.nextMedia(after: ref(season: 1, episode: 1), in: context))
        #expect(next.url.absoluteString.contains("/series/"))
        #expect(!next.isLive)
    }

    @Test func `movie input has no next episode`() throws {
        let (context, _, _) = try makeWorld(episodes: twoSeasons)
        #expect(NextEpisodeResolver.nextMedia(after: .movie("m-1"), in: context) == nil)
    }

    @Test func `live input has no next episode`() throws {
        let (context, _, _) = try makeWorld(episodes: twoSeasons)
        #expect(NextEpisodeResolver.nextMedia(after: .live("l-1"), in: context) == nil)
    }

    @Test func `previous within the same season`() throws {
        let (context, _, _) = try makeWorld(episodes: twoSeasons)
        let previous = NextEpisodeResolver.previousMedia(before: ref(season: 1, episode: 2), in: context)
        #expect(previous?.contentRef == ref(season: 1, episode: 1))
    }

    @Test func `previous crosses the season boundary backwards`() throws {
        // The first episode of season 2 should fall back to the last of season 1.
        let (context, _, _) = try makeWorld(episodes: twoSeasons)
        let previous = NextEpisodeResolver.previousMedia(before: ref(season: 2, episode: 1), in: context)
        #expect(previous?.contentRef == ref(season: 1, episode: 2))
    }

    @Test func `series premiere has no previous episode`() throws {
        let (context, _, _) = try makeWorld(episodes: twoSeasons)
        let previous = NextEpisodeResolver.previousMedia(before: ref(season: 1, episode: 1), in: context)
        #expect(previous == nil)
    }

    @Test func `resolved previous media carries a playable URL`() throws {
        let (context, _, _) = try makeWorld(episodes: twoSeasons)
        let previous = try #require(
            NextEpisodeResolver.previousMedia(before: ref(season: 2, episode: 1), in: context)
        )
        #expect(previous.url.absoluteString.contains("/series/"))
        #expect(!previous.isLive)
    }

    @Test func `movie input has no previous episode`() throws {
        let (context, _, _) = try makeWorld(episodes: twoSeasons)
        #expect(NextEpisodeResolver.previousMedia(before: .movie("m-1"), in: context) == nil)
    }

    @Test func `live input has no previous episode`() throws {
        let (context, _, _) = try makeWorld(episodes: twoSeasons)
        #expect(NextEpisodeResolver.previousMedia(before: .live("l-1"), in: context) == nil)
    }

    @Test func `next skips duplicate episode positions to the next distinct position`() throws {
        // Show has S1E1, two versions of S1E2 (ep-a and ep-b), and S1E3.
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "P", serverURL: "http://example.com", username: "u", password: "p")
        context.insert(playlist)
        let series = Series(id: "\(playlist.id.uuidString)-series-dup", seriesId: 2, name: "DupShow")
        context.insert(series)

        let ep1 = Episode(id: "ep-1", episodeId: "1", title: "E1", containerExtension: "mkv", seasonNum: 1, episodeNum: 1, series: series)
        let ep2a = Episode(id: "ep-2a", episodeId: "2a", title: "E2 A", containerExtension: "mkv", seasonNum: 1, episodeNum: 2, series: series)
        let ep2b = Episode(id: "ep-2b", episodeId: "2b", title: "E2 B", containerExtension: "mkv", seasonNum: 1, episodeNum: 2, series: series)
        let ep3 = Episode(id: "ep-3", episodeId: "3", title: "E3", containerExtension: "mkv", seasonNum: 1, episodeNum: 3, series: series)
        for ep in [ep1, ep2a, ep2b, ep3] {
            context.insert(ep)
            series.episodes.append(ep)
        }
        try context.save()

        // From ep2a, the next episode should advance to S1E3, skipping the duplicate S1E2 (ep2b).
        let next = NextEpisodeResolver.nextMedia(after: .episode("ep-2a"), in: context)
        #expect(next?.contentRef == .episode("ep-3"))

        // From ep2b, previous should be S1E1, skipping ep2a.
        let prev = NextEpisodeResolver.previousMedia(before: .episode("ep-2b"), in: context)
        #expect(prev?.contentRef == .episode("ep-1"))
    }

    @Test func `season boundary crosses non-consecutive seasons`() throws {
        // Show has Season 1 and Season 3 (Season 2 is missing).
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "P", serverURL: "http://example.com", username: "u", password: "p")
        context.insert(playlist)
        let series = Series(id: "\(playlist.id.uuidString)-series-gap", seriesId: 3, name: "GapShow")
        context.insert(series)

        let s1e1 = Episode(id: "s1e1", episodeId: "101", title: "S1E1", containerExtension: "mkv", seasonNum: 1, episodeNum: 1, series: series)
        let s3e1 = Episode(id: "s3e1", episodeId: "301", title: "S3E1", containerExtension: "mkv", seasonNum: 3, episodeNum: 1, series: series)
        for ep in [s1e1, s3e1] {
            context.insert(ep)
            series.episodes.append(ep)
        }
        try context.save()

        let next = NextEpisodeResolver.nextMedia(after: .episode("s1e1"), in: context)
        #expect(next?.contentRef == .episode("s3e1"))

        let prev = NextEpisodeResolver.previousMedia(before: .episode("s3e1"), in: context)
        #expect(prev?.contentRef == .episode("s1e1"))
    }
}

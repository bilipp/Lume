//
//  NextEpisodeResolverTests.swift
//  LumeTests
//
//  Covers the "play next" resolution behind auto-advance and the in-player Next
//  Episode button (`NextEpisodeResolver.nextMedia`): season-internal ordering,
//  crossing a season boundary, the series finale, and non-episode input.
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
}

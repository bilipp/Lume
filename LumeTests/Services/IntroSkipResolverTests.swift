//
//  IntroSkipResolverTests.swift
//  LumeTests
//
//  Covers `IntroSkipResolver.lookup` — the IntroDB key is only resolvable for an
//  episode whose series carries a usable IMDb id; everything else must quietly
//  resolve to `nil` so the player drops the affordance instead of querying.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct IntroSkipResolverTests {
    private static let episodeID = "ep-s2e5"

    private func makeWorld(seriesIMDbId: String?) throws -> ModelContext {
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
        series.imdbId = seriesIMDbId
        context.insert(series)

        let episode = Episode(
            id: Self.episodeID,
            episodeId: "25",
            title: "S2E5",
            containerExtension: "mkv",
            seasonNum: 2,
            episodeNum: 5,
            series: series
        )
        context.insert(episode)
        series.episodes.append(episode)
        try context.save()
        return context
    }

    @Test func `a well-formed episode resolves the IntroDB key`() throws {
        let context = try makeWorld(seriesIMDbId: "tt0903747")
        let lookup = IntroSkipResolver.lookup(for: .episode(Self.episodeID), in: context)

        #expect(lookup == IntroSkipResolver.Lookup(imdbId: "tt0903747", season: 2, episode: 5))
    }

    @Test func `a surrounding-whitespace imdb id is trimmed`() throws {
        let context = try makeWorld(seriesIMDbId: "  tt0903747 ")
        let lookup = IntroSkipResolver.lookup(for: .episode(Self.episodeID), in: context)

        #expect(lookup?.imdbId == "tt0903747")
    }

    @Test func `a series without an imdb id resolves to nil`() throws {
        let context = try makeWorld(seriesIMDbId: nil)

        #expect(IntroSkipResolver.lookup(for: .episode(Self.episodeID), in: context) == nil)
    }

    @Test func `a whitespace-only imdb id resolves to nil`() throws {
        let context = try makeWorld(seriesIMDbId: "   ")

        #expect(IntroSkipResolver.lookup(for: .episode(Self.episodeID), in: context) == nil)
    }

    @Test func `an unknown episode id resolves to nil`() throws {
        let context = try makeWorld(seriesIMDbId: "tt0903747")

        #expect(IntroSkipResolver.lookup(for: .episode("no-such-episode"), in: context) == nil)
    }

    @Test func `movies and live streams resolve to nil`() throws {
        // IntroDB indexes episodic TV only — its endpoint requires season/episode.
        let context = try makeWorld(seriesIMDbId: "tt0903747")

        #expect(IntroSkipResolver.lookup(for: .movie(Self.episodeID), in: context) == nil)
        #expect(IntroSkipResolver.lookup(for: .live(Self.episodeID), in: context) == nil)
    }
}

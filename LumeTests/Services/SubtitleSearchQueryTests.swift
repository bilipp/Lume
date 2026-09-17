//
//  SubtitleSearchQueryTests.swift
//  LumeTests
//
//  Covers the OpenSubtitles lookup key the in-player search runs on
//  (`SubtitleSearchQuery.resolve`): movies key on their own ids, episodes on
//  their *series'* ids plus season/episode, and live channels resolve to nothing.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct SubtitleSearchQueryTests {
    private func makeContext() throws -> ModelContext {
        try ModelContext(makeTestContainer())
    }

    // MARK: - Movies

    @Test func `a movie resolves to its own title and ids`() throws {
        let context = try makeContext()
        let movie = Movie(id: "movie-1", streamId: 1, name: "Fight Club")
        movie.imdbId = "tt0137523"
        movie.tmdbId = 550
        context.insert(movie)
        try context.save()

        let query = try #require(SubtitleSearchQuery.resolve(for: .movie("movie-1"), in: context))
        #expect(query.text == "Fight Club")
        #expect(query.imdbId == "tt0137523")
        #expect(query.tmdbId == 550)
        #expect(query.season == nil)
        #expect(query.episode == nil)
    }

    /// An unenriched movie still searches — by title alone, which is the whole
    /// reason the text field rides along with the ids.
    @Test func `a movie with no ids still resolves on its title`() throws {
        let context = try makeContext()
        context.insert(Movie(id: "movie-2", streamId: 2, name: "Some Import"))
        try context.save()

        let query = try #require(SubtitleSearchQuery.resolve(for: .movie("movie-2"), in: context))
        #expect(query.text == "Some Import")
        #expect(query.tmdbId == nil)
        #expect(query.isEmpty == false)
    }

    // MARK: - Episodes

    @Test func `an episode resolves to the series ids plus season and episode`() throws {
        let context = try makeContext()
        let series = Series(id: "series-1", seriesId: 1, name: "Breaking Bad")
        series.imdbId = "tt0903747"
        series.tmdbId = 1396
        context.insert(series)
        let episode = Episode(
            id: "ep-1",
            episodeId: "1",
            title: "Pilot",
            containerExtension: "mkv",
            seasonNum: 1,
            episodeNum: 1,
            series: series
        )
        context.insert(episode)
        series.episodes.append(episode)
        try context.save()

        let query = try #require(SubtitleSearchQuery.resolve(for: .episode("ep-1"), in: context))
        // The show's name, not the episode's — that is how OpenSubtitles
        // indexes episodes.
        #expect(query.text == "Breaking Bad")
        #expect(query.parentImdbId == "tt0903747")
        #expect(query.parentTmdbId == 1396)
        #expect(query.season == 1)
        #expect(query.episode == 1)
        // The episode never carries the *feature* ids, which would search for a
        // movie of the same name.
        #expect(query.tmdbId == nil)
        #expect(query.imdbId == nil)
    }

    @Test func `an orphaned episode falls back to its own title`() throws {
        let context = try makeContext()
        let episode = Episode(
            id: "ep-2",
            episodeId: "2",
            title: "Loose Episode",
            containerExtension: "mkv",
            seasonNum: 2,
            episodeNum: 3,
            series: nil
        )
        context.insert(episode)
        try context.save()

        let query = try #require(SubtitleSearchQuery.resolve(for: .episode("ep-2"), in: context))
        #expect(query.text == "Loose Episode")
        #expect(query.season == 2)
        #expect(query.episode == 3)
        #expect(query.parentTmdbId == nil)
    }

    // MARK: - Nothing to search

    @Test func `a live channel resolves to nothing`() throws {
        let context = try makeContext()
        #expect(SubtitleSearchQuery.resolve(for: .live("live-1"), in: context) == nil)
    }

    @Test func `an unknown title resolves to nothing`() throws {
        let context = try makeContext()
        #expect(SubtitleSearchQuery.resolve(for: .movie("missing"), in: context) == nil)
        #expect(SubtitleSearchQuery.resolve(for: .episode("missing"), in: context) == nil)
    }

    // MARK: - Search availability

    @MainActor
    @Test func `search is never offered for a live stream`() throws {
        let live = try PlayableMedia(
            id: "live-1",
            url: #require(URL(string: "http://example.com/live.ts")),
            title: "Channel",
            subtitle: nil,
            posterURL: nil,
            kind: .live,
            startTime: 0,
            contentRef: .live("live-1")
        )
        #expect(OpenSubtitlesService.supportsSearch(for: live) == false)
    }
}

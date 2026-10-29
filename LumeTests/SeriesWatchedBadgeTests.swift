//
//  SeriesWatchedBadgeTests.swift
//  LumeTests
//
//  Covers the series poster card's "every episode watched" check (#206).
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SeriesWatchedBadgeTests {
    private func makeSeries(_ id: String, watched: [Bool], in ctx: ModelContext) -> Series {
        let series = Series(id: id, seriesId: 1, name: "A Show", categoryId: "cat")
        ctx.insert(series)
        for (index, isWatched) in watched.enumerated() {
            let episode = Episode(id: "\(id)-e\(index)", episodeId: "\(index)", title: "E\(index)", containerExtension: "mkv", seasonNum: 1, episodeNum: index + 1)
            ctx.insert(episode)
            episode.isWatched = isWatched
            series.episodes.append(episode)
        }
        return series
    }

    @Test func `a series with every episode watched is watched`() throws {
        let container = try makeTestContainer()
        let ctx = container.mainContext
        _ = makeSeries("s1", watched: [true, true, true], in: ctx)
        try ctx.save()
        #expect(SeriesEpisodeProgress.allEpisodesWatched(seriesID: "s1", in: ctx))
    }

    @Test func `one unwatched episode keeps the series unwatched`() throws {
        let container = try makeTestContainer()
        let ctx = container.mainContext
        _ = makeSeries("s1", watched: [true, false, true], in: ctx)
        try ctx.save()
        #expect(!SeriesEpisodeProgress.allEpisodesWatched(seriesID: "s1", in: ctx))
    }

    @Test func `a series without fetched episodes is not watched`() throws {
        let container = try makeTestContainer()
        let ctx = container.mainContext
        _ = makeSeries("s1", watched: [], in: ctx)
        try ctx.save()
        #expect(!SeriesEpisodeProgress.allEpisodesWatched(seriesID: "s1", in: ctx))
    }

    @Test func `another series' episodes don't count`() throws {
        let container = try makeTestContainer()
        let ctx = container.mainContext
        _ = makeSeries("s1", watched: [true], in: ctx)
        _ = makeSeries("s2", watched: [false, false], in: ctx)
        try ctx.save()
        #expect(SeriesEpisodeProgress.allEpisodesWatched(seriesID: "s1", in: ctx))
        #expect(!SeriesEpisodeProgress.allEpisodesWatched(seriesID: "s2", in: ctx))
    }
}

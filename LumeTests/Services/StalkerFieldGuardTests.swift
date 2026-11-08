//
//  StalkerFieldGuardTests.swift
//  LumeTests
//
//  Re-applying an unchanged Stalker row must leave the context clean, so an
//  unchanged sync saves nothing and re-runs no live-TV query.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct StalkerFieldGuardTests {
    private func decode<T: Decodable>(_: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private let vodJSON = """
    {"id":"12","name":"A Film","cmd":"ffrt http://portal/12","screenshot":"http://img/12.jpg",
     "year":"2021","description":"A plot.","rating":"7.5","genre_id":"3","added":"2024-01-01 10:00:00"}
    """

    @Test func `an unchanged movie leaves the context clean`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let manager = ContentSyncManager(modelContainer: container)
        let item = try decode(StalkerVODItem.self, vodJSON)
        let movie = Movie(id: "p-movie-12", streamId: 12, name: "")
        context.insert(movie)

        await manager.applyStalkerMovieFields(from: item, cmd: "ffrt http://portal/12", to: movie, categoryId: "p-vod-3")
        try context.save()
        await manager.applyStalkerMovieFields(from: item, cmd: "ffrt http://portal/12", to: movie, categoryId: "p-vod-3")

        #expect(!context.hasChanges)
        #expect(movie.name == "A Film")
        #expect(movie.rating == 7.5)
    }

    @Test func `an unchanged series leaves the context clean`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let manager = ContentSyncManager(modelContainer: container)
        let item = try decode(StalkerVODItem.self, vodJSON)
        let series = Series(id: "p-series-12", seriesId: 12, name: "")
        context.insert(series)

        await manager.applyStalkerSeriesFields(from: item, to: series, categoryId: "p-series-3")
        try context.save()
        await manager.applyStalkerSeriesFields(from: item, to: series, categoryId: "p-series-3")

        #expect(!context.hasChanges)
        #expect(series.lastModified == "1704103200")
    }

    @Test func `a timestamp stored in the portal's own format is not rewritten`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let manager = ContentSyncManager(modelContainer: container)
        let item = try decode(StalkerVODItem.self, vodJSON)
        let movie = Movie(id: "p-movie-12", streamId: 12, name: "")
        let series = Series(id: "p-series-12", seriesId: 12, name: "")
        context.insert(movie)
        context.insert(series)
        await manager.applyStalkerMovieFields(from: item, cmd: "ffrt http://portal/12", to: movie, categoryId: "p-vod-3")
        await manager.applyStalkerSeriesFields(from: item, to: series, categoryId: "p-series-3")
        movie.added = "2024-01-01 10:00:00"
        series.lastModified = "2024-01-01 10:00:00"
        series.episodesFetchedAt = Date()
        series.episodesFetchedLastModified = "2024-01-01 10:00:00"
        try context.save()

        await manager.applyStalkerMovieFields(from: item, cmd: "ffrt http://portal/12", to: movie, categoryId: "p-vod-3")
        await manager.applyStalkerSeriesFields(from: item, to: series, categoryId: "p-series-3")

        #expect(!context.hasChanges)
        #expect(movie.added == "2024-01-01 10:00:00")
        #expect(!series.episodesAreStale(lastSyncedAt: nil))
    }

    @Test func `an unchanged channel leaves the context clean, a renamed one does not`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let manager = ContentSyncManager(modelContainer: container)
        let channel = try decode(StalkerChannel.self, """
        {"id":"5","name":"News HD","number":"5","cmd":"ffrt http://portal/ch/5","logo":"http://img/5.png",
         "tv_genre_id":"2","xmltv_id":"news.hd"}
        """)
        let stream = LiveStream(id: "p-live-5", streamId: 5, name: "")
        context.insert(stream)

        await manager.applyStalkerChannelFields(from: channel, cmd: "ffrt http://portal/ch/5", to: stream, playlistPrefix: "p-live-")
        try context.save()
        await manager.applyStalkerChannelFields(from: channel, cmd: "ffrt http://portal/ch/5", to: stream, playlistPrefix: "p-live-")
        #expect(!context.hasChanges)

        let renamed = try decode(StalkerChannel.self, """
        {"id":"5","name":"News 24","number":"5","cmd":"ffrt http://portal/ch/5","logo":"http://img/5.png",
         "tv_genre_id":"2","xmltv_id":"news.hd"}
        """)
        await manager.applyStalkerChannelFields(from: renamed, cmd: "ffrt http://portal/ch/5", to: stream, playlistPrefix: "p-live-")
        #expect(context.hasChanges)
        #expect(stream.name == "News 24")
    }
}

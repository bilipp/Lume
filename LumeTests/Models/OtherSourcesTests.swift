//
//  OtherSourcesTests.swift
//  LumeTests
//
//  Coverage for the detail screens' combined "Other Sources" row: same-playlist
//  alternates first (unlabelled), then cross-playlist copies badged with the
//  owning playlist's name — never from a playlist the free plan locks.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct OtherSourcesTests {
    private func makePlaylist(name: String, in context: ModelContext) -> Playlist {
        let playlist = Playlist(name: name, serverURL: "http://x.com", username: "u", password: "p")
        context.insert(playlist)
        return playlist
    }

    private func makeMovie(id: String, streamId: Int, tmdbId: Int?, in context: ModelContext) -> Movie {
        let movie = Movie(id: id, streamId: streamId, name: "Movie \(streamId)")
        movie.tmdbId = tmdbId
        context.insert(movie)
        return movie
    }

    private func makeSeries(id: String, seriesId: Int, tmdbId: Int?, in context: ModelContext) -> Series {
        let series = Series(id: id, seriesId: seriesId, name: "Series \(seriesId)")
        series.tmdbId = tmdbId
        context.insert(series)
        return series
    }

    @Test func `movie sources list same-playlist alternates first, then badged cross-playlist copies`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let playlistA = makePlaylist(name: "Provider A", in: context)
        let playlistB = makePlaylist(name: "Provider B", in: context)

        let current = makeMovie(id: "\(playlistA.id.uuidString)-movie-1", streamId: 1, tmdbId: 42, in: context)
        let sameList = makeMovie(id: "\(playlistA.id.uuidString)-movie-2", streamId: 2, tmdbId: 42, in: context)
        let otherList = makeMovie(id: "\(playlistB.id.uuidString)-movie-3", streamId: 3, tmdbId: 42, in: context)
        _ = makeMovie(id: "\(playlistB.id.uuidString)-movie-4", streamId: 4, tmdbId: 7, in: context)
        try context.save()

        let sources = OtherSources.resolve(for: current, in: context, isPremium: true)
        #expect(sources.map(\.id) == [HomeMediaItem.movie(sameList).id, HomeMediaItem.movie(otherList).id])
        #expect(sources.map(\.playlistName) == [nil, "Provider B"])
    }

    @Test func `series sources badge cross-playlist copies with the owning playlist's name`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let playlistA = makePlaylist(name: "Provider A", in: context)
        let playlistB = makePlaylist(name: "Provider B", in: context)

        let current = makeSeries(id: "\(playlistA.id.uuidString)-series-1", seriesId: 1, tmdbId: 314, in: context)
        let otherList = makeSeries(id: "\(playlistB.id.uuidString)-series-2", seriesId: 2, tmdbId: 314, in: context)
        try context.save()

        let sources = OtherSources.resolve(for: current, in: context, isPremium: true)
        #expect(sources.map(\.id) == [HomeMediaItem.series(otherList).id])
        #expect(sources.map(\.playlistName) == ["Provider B"])
    }

    @Test func `cross-playlist sources sort by playlist name`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let home = makePlaylist(name: "Home", in: context)
        let zeta = makePlaylist(name: "Zeta TV", in: context)
        let alpha = makePlaylist(name: "Alpha IPTV", in: context)

        let current = makeMovie(id: "\(home.id.uuidString)-movie-1", streamId: 1, tmdbId: 42, in: context)
        _ = makeMovie(id: "\(zeta.id.uuidString)-movie-2", streamId: 2, tmdbId: 42, in: context)
        _ = makeMovie(id: "\(alpha.id.uuidString)-movie-3", streamId: 3, tmdbId: 42, in: context)
        try context.save()

        let names = OtherSources.resolve(for: current, in: context, isPremium: true).map(\.playlistName)
        #expect(names == ["Alpha IPTV", "Zeta TV"])
    }

    @Test func `cross-playlist copies with no owning playlist are dropped`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let playlist = makePlaylist(name: "Provider A", in: context)

        let current = makeMovie(id: "\(playlist.id.uuidString)-movie-1", streamId: 1, tmdbId: 42, in: context)
        _ = makeMovie(id: "\(UUID().uuidString)-movie-2", streamId: 2, tmdbId: 42, in: context)
        try context.save()

        #expect(OtherSources.resolve(for: current, in: context).isEmpty)
    }

    @Test func `without Pro copies on locked playlists are dropped, alternates on the free one kept`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let free = makePlaylist(name: "Provider A", in: context)
        let locked = makePlaylist(name: "Provider B", in: context)
        free.addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        locked.addedAt = Date(timeIntervalSince1970: 1_700_000_001)

        let current = makeMovie(id: "\(free.id.uuidString)-movie-1", streamId: 1, tmdbId: 42, in: context)
        let sameList = makeMovie(id: "\(free.id.uuidString)-movie-2", streamId: 2, tmdbId: 42, in: context)
        _ = makeMovie(id: "\(locked.id.uuidString)-movie-3", streamId: 3, tmdbId: 42, in: context)
        try context.save()

        let sources = OtherSources.resolve(for: current, in: context, isPremium: false)
        #expect(sources.map(\.id) == [HomeMediaItem.movie(sameList).id])
        #expect(sources.map(\.playlistName) == [nil])
    }

    @Test func `sources are empty without a tmdb id`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let playlistA = makePlaylist(name: "Provider A", in: context)
        let playlistB = makePlaylist(name: "Provider B", in: context)

        let current = makeMovie(id: "\(playlistA.id.uuidString)-movie-1", streamId: 1, tmdbId: nil, in: context)
        _ = makeMovie(id: "\(playlistB.id.uuidString)-movie-2", streamId: 2, tmdbId: nil, in: context)
        try context.save()

        #expect(OtherSources.resolve(for: current, in: context).isEmpty)
    }
}

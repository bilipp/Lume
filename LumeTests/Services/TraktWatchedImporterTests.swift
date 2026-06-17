import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct TraktWatchedImporterTests {
    private func makeContext() throws -> ModelContext {
        try ModelContext(makeTestContainer())
    }

    private func makeMovie(id: String, tmdbId: Int?, duration: Int? = 7200) -> Movie {
        let movie = Movie(id: id, streamId: 1, name: "Movie \(id)")
        movie.tmdbId = tmdbId
        movie.durationSecs = duration
        return movie
    }

    private func watchedMovie(tmdb: Int, lastWatchedAt: String? = nil) -> TraktWatchedMovie {
        TraktWatchedMovie(movie: TraktWatchedMedia(ids: TraktIDs(tmdb: tmdb, trakt: nil)), lastWatchedAt: lastWatchedAt)
    }

    @Test func `marks matching movies watched and leaves the rest untouched`() throws {
        let context = try makeContext()
        let match = makeMovie(id: "a", tmdbId: 100)
        let other = makeMovie(id: "b", tmdbId: 200)
        context.insert(match)
        context.insert(other)

        let summary = TraktWatchedImporter.apply(movies: [watchedMovie(tmdb: 100)], shows: [], in: context)

        #expect(summary.moviesMarked == 1)
        #expect(match.isWatched == true)
        #expect(match.watchProgress == 7200)
        #expect(other.isWatched == false)
    }

    @Test func `applies the trakt last-watched date when present`() throws {
        let context = try makeContext()
        let movie = makeMovie(id: "a", tmdbId: 100)
        context.insert(movie)

        let summary = TraktWatchedImporter.apply(
            movies: [watchedMovie(tmdb: 100, lastWatchedAt: "2014-10-11T17:00:54.000Z")],
            shows: [],
            in: context
        )

        #expect(summary.moviesMarked == 1)
        let expected = ISO8601DateFormatter().date(from: "2014-10-11T17:00:54Z")
        #expect(movie.lastWatchedDate == expected)
    }

    @Test func `already-watched movies are not re-counted`() throws {
        let context = try makeContext()
        let movie = makeMovie(id: "a", tmdbId: 100)
        movie.isWatched = true
        context.insert(movie)

        let summary = TraktWatchedImporter.apply(movies: [watchedMovie(tmdb: 100)], shows: [], in: context)

        #expect(summary.moviesMarked == 0)
        #expect(summary.markedNothing == true)
    }

    @Test func `marks only the episodes trakt reports watched`() throws {
        let context = try makeContext()
        let series = Series(id: "s1", seriesId: 1, name: "Show")
        series.tmdbId = 300
        let ep1 = Episode(id: "s1-1", episodeId: "1", title: "E1", containerExtension: "mkv", seasonNum: 1, episodeNum: 1)
        let ep2 = Episode(id: "s1-2", episodeId: "2", title: "E2", containerExtension: "mkv", seasonNum: 1, episodeNum: 2)
        ep1.durationSecs = 1200
        ep1.series = series
        ep2.series = series
        series.episodes = [ep1, ep2]
        context.insert(series)

        let show = TraktWatchedShow(
            show: TraktWatchedMedia(ids: TraktIDs(tmdb: 300, trakt: nil)),
            seasons: [TraktWatchedSeason(number: 1, episodes: [TraktWatchedEpisode(number: 1, lastWatchedAt: nil)])]
        )
        let summary = TraktWatchedImporter.apply(movies: [], shows: [show], in: context)

        #expect(summary.episodesMarked == 1)
        #expect(ep1.isWatched == true)
        #expect(ep1.watchProgress == 1200)
        #expect(ep2.isWatched == false)
    }

    @Test func `titles without a tmdb id are skipped`() throws {
        let context = try makeContext()
        let movie = makeMovie(id: "a", tmdbId: nil)
        context.insert(movie)

        let summary = TraktWatchedImporter.apply(movies: [watchedMovie(tmdb: 100)], shows: [], in: context)

        #expect(summary.moviesMarked == 0)
        #expect(movie.isWatched == false)
    }
}

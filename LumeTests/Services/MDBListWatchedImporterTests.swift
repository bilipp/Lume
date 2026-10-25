import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.serialized)
struct MDBListWatchedImporterTests {
    init() {
        // The parked-progress store is a file plus an in-memory cache; every test
        // starts from empty so they can't leak into one another.
        MDBListPendingWatchedStore.clearAll()
        MDBListPendingWatchedStore.resetCacheForTesting()
    }

    private func makeContext() throws -> ModelContext {
        try ModelContext(makeTestContainer())
    }

    private let watchedAt = "2025-10-15T20:00:00Z"
    private var watchedDate: Date? {
        ISO8601DateFormatter().date(from: watchedAt)
    }

    private func history(movies: [MDBListWatchedMovie] = [], episodes: [MDBListWatchedEpisode] = []) -> MDBListWatchedHistory {
        MDBListWatchedHistory(movies: movies, episodes: episodes)
    }

    private func watchedMovie(tmdb: Int?, lastWatchedAt: String? = "2025-10-15T20:00:00Z") -> MDBListWatchedMovie {
        MDBListWatchedMovie(lastWatchedAt: lastWatchedAt, movie: MDBListWatchedMedia(ids: MDBListIDs(tmdb: tmdb)))
    }

    private func watchedEpisode(show: Int, season: Int = 1, number: Int, date: String? = "2025-10-15T20:00:00Z") -> MDBListWatchedEpisode {
        MDBListWatchedEpisode(
            lastWatchedAt: date,
            episode: .init(season: season, number: number, show: MDBListWatchedMedia(ids: MDBListIDs(tmdb: show)))
        )
    }

    private func makeMovie(id: String, tmdbId: Int?, duration: Int? = 7200) -> Movie {
        let movie = Movie(id: id, streamId: 1, name: "Movie \(id)")
        movie.tmdbId = tmdbId
        movie.durationSecs = duration
        return movie
    }

    private func makeSeries(withEpisodes count: Int) -> Series {
        let series = Series(id: "s1", seriesId: 1, name: "Show")
        series.tmdbId = 300
        for number in 0 ..< count {
            let episode = Episode(
                id: "s1-\(number + 1)", episodeId: "\(number + 1)", title: "E\(number + 1)",
                containerExtension: "mkv", seasonNum: 1, episodeNum: number + 1
            )
            episode.durationSecs = 1200
            episode.series = series
            series.episodes.append(episode)
        }
        return series
    }

    private func parsedEpisode(_ number: Int) -> ParsedEpisode {
        ParsedEpisode(
            id: "s1-\(number)", episodeId: "\(number)", title: "E\(number)",
            containerExtension: "mkv", seasonNum: 1, episodeNum: number,
            added: nil, directSource: nil, durationSecs: 1200,
            movieImage: nil, rating: nil, airDate: nil, plot: nil
        )
    }

    // MARK: - Movies

    @Test func `marks matching movies watched and leaves the rest untouched`() throws {
        let context = try makeContext()
        let match = makeMovie(id: "a", tmdbId: 100)
        let other = makeMovie(id: "b", tmdbId: 200)
        context.insert(match)
        context.insert(other)

        let summary = MDBListWatchedImporter.apply(history: history(movies: [watchedMovie(tmdb: 100)]), in: context)

        #expect(summary.moviesMarked == 1)
        #expect(match.isWatched == true)
        #expect(match.watchProgress == 7200)
        #expect(match.lastWatchedDate == watchedDate)
        #expect(other.isWatched == false)
    }

    @Test func `a row without a watched timestamp is not marked`() throws {
        // Unwatching on MDBList keeps the row with a null timestamp.
        let context = try makeContext()
        let movie = makeMovie(id: "a", tmdbId: 100)
        context.insert(movie)

        let summary = MDBListWatchedImporter.apply(
            history: history(movies: [watchedMovie(tmdb: 100, lastWatchedAt: nil)]),
            in: context
        )

        #expect(summary.markedNothing == true)
        #expect(movie.isWatched == false)
    }

    @Test func `already-watched movies are not re-counted`() throws {
        let context = try makeContext()
        let movie = makeMovie(id: "a", tmdbId: 100)
        movie.isWatched = true
        context.insert(movie)

        let summary = MDBListWatchedImporter.apply(history: history(movies: [watchedMovie(tmdb: 100)]), in: context)

        #expect(summary.moviesMarked == 0)
        #expect(summary.markedNothing == true)
    }

    @Test func `titles without a tmdb id are skipped`() throws {
        let context = try makeContext()
        let movie = makeMovie(id: "a", tmdbId: nil)
        context.insert(movie)

        let summary = MDBListWatchedImporter.apply(history: history(movies: [watchedMovie(tmdb: nil)]), in: context)

        #expect(summary.moviesMarked == 0)
        #expect(movie.isWatched == false)
    }

    // MARK: - Episodes

    @Test func `marks only the episodes mdblist reports watched`() throws {
        let context = try makeContext()
        let series = makeSeries(withEpisodes: 2)
        context.insert(series)

        let summary = MDBListWatchedImporter.apply(
            history: history(episodes: [watchedEpisode(show: 300, number: 1), watchedEpisode(show: 300, season: 2, number: 2)]),
            in: context
        )

        let first = try #require(series.episodes.first { $0.episodeNum == 1 })
        let second = try #require(series.episodes.first { $0.episodeNum == 2 })
        #expect(summary.episodesMarked == 1)
        #expect(first.isWatched == true)
        #expect(first.watchProgress == 1200)
        #expect(second.isWatched == false)
        #expect(series.lastWatchedDate == watchedDate)
        #expect(MDBListPendingWatchedStore.load()[300] == nil)
    }

    @Test func `episode rows group by show and keep the newest timestamp`() {
        let progress = MDBListWatchedImporter.progressByShow([
            watchedEpisode(show: 300, number: 1, date: "2025-10-01T00:00:00Z"),
            watchedEpisode(show: 300, number: 1, date: "2025-10-15T20:00:00Z"),
            watchedEpisode(show: 400, number: 3),
            watchedEpisode(show: 500, number: 1, date: nil)
        ])

        #expect(Set(progress.keys) == [300, 400])
        #expect(progress[300]?.dates[.init(season: 1, episode: 1)] == watchedDate)
    }

    @Test func `a series with no local episodes parks its progress for later`() throws {
        let context = try makeContext()
        let series = makeSeries(withEpisodes: 0)
        context.insert(series)

        let summary = MDBListWatchedImporter.apply(history: history(episodes: [watchedEpisode(show: 300, number: 2)]), in: context)

        #expect(summary.episodesMarked == 0)
        #expect(summary.showsQueued == 1)
        // Home's Recently Watched row works straight away, without the episodes.
        #expect(series.lastWatchedDate == watchedDate)
        #expect(MDBListPendingWatchedStore.load()[300]?.episodes["1x2"] != nil)
    }

    @Test func `parked progress is applied when the episodes arrive`() throws {
        let context = try makeContext()
        let series = makeSeries(withEpisodes: 0)
        context.insert(series)
        _ = MDBListWatchedImporter.apply(history: history(episodes: [watchedEpisode(show: 300, number: 2)]), in: context)

        // What the detail screen does on first open.
        series.insertEpisodes([parsedEpisode(1), parsedEpisode(2)], into: context)

        #expect(series.episodes.first { $0.episodeNum == 2 }?.isWatched == true)
        #expect(series.episodes.first { $0.episodeNum == 2 }?.watchProgress == 1200)
        #expect(series.episodes.first { $0.episodeNum == 1 }?.isWatched == false)
        // The entry is consumed, so a later fetch can't re-apply it.
        #expect(MDBListPendingWatchedStore.load()[300] == nil)
    }
}

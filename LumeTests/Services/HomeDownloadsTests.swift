import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct HomeDownloadsTests {
    private func movie(_ id: String, downloadedAt: Date, categoryId: String? = nil) -> Movie {
        let movie = Movie(id: id, streamId: 0, name: id, categoryId: categoryId)
        movie.downloadedAt = downloadedAt
        return movie
    }

    private func episode(_ id: String, of series: Series, downloadedAt: Date) -> Episode {
        let episode = Episode(
            id: id, episodeId: id, title: id, containerExtension: "mp4",
            seasonNum: 1, episodeNum: 1, series: series
        )
        episode.downloadedAt = downloadedAt
        return episode
    }

    @Test func `episodes collapse into one card per series`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let show = Series(id: "s1", seriesId: 1, name: "Show")
        context.insert(show)
        let now = Date()
        let episodes = [
            episode("e2", of: show, downloadedAt: now),
            episode("e1", of: show, downloadedAt: now.addingTimeInterval(-60))
        ]
        episodes.forEach(context.insert)

        let items = HomeDownloads.items(movies: [], episodes: episodes, restriction: ContentRestriction())

        #expect(items.map(\.id) == ["series-s1"])
    }

    @Test func `movies and series interleave newest first`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let show = Series(id: "s1", seriesId: 1, name: "Show")
        context.insert(show)
        let now = Date()
        let older = movie("m1", downloadedAt: now.addingTimeInterval(-120))
        let newer = movie("m2", downloadedAt: now)
        [older, newer].forEach(context.insert)
        let downloaded = episode("e1", of: show, downloadedAt: now.addingTimeInterval(-60))
        context.insert(downloaded)

        let items = HomeDownloads.items(movies: [newer, older], episodes: [downloaded], restriction: ContentRestriction())

        #expect(items.map(\.id) == ["movie-m2", "series-s1", "movie-m1"])
    }

    @Test func `hidden categories are left out`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let show = Series(id: "s1", seriesId: 1, name: "Show", categoryId: "hidden")
        context.insert(show)
        let hiddenMovie = movie("m1", downloadedAt: Date(), categoryId: "hidden")
        let shownMovie = movie("m2", downloadedAt: Date())
        [hiddenMovie, shownMovie].forEach(context.insert)
        let downloaded = episode("e1", of: show, downloadedAt: Date())
        context.insert(downloaded)

        let items = HomeDownloads.items(
            movies: [hiddenMovie, shownMovie],
            episodes: [downloaded],
            restriction: ContentRestriction(hiddenCategoryIDs: ["hidden"])
        )

        #expect(items.map(\.id) == ["movie-m2"])
    }

    @Test func `row is capped`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let now = Date()
        let movies = (0 ..< HomeDownloads.limit + 5).map { movie("m\($0)", downloadedAt: now.addingTimeInterval(-Double($0))) }
        movies.forEach(context.insert)

        let items = HomeDownloads.items(movies: movies, episodes: [], restriction: ContentRestriction())

        #expect(items.count == HomeDownloads.limit)
    }
}

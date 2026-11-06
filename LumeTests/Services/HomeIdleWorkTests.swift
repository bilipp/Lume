import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct HomeIdleWorkTests {
    // MARK: - Helpers

    private func makeMovie(id: String, name: String = "Movie", lastWatchedDate: Date? = nil, isFavorite: Bool = false, favoriteOrder: Int? = nil, categoryId: String? = nil) -> Movie {
        let movie = Movie(id: id, streamId: 0, name: name, categoryId: categoryId)
        movie.lastWatchedDate = lastWatchedDate
        movie.isFavorite = isFavorite
        movie.favoriteOrder = favoriteOrder
        return movie
    }

    private func makeSeries(id: String, name: String = "Series", lastWatchedDate: Date? = nil, isFavorite: Bool = false, favoriteOrder: Int? = nil, categoryId: String? = nil) -> Series {
        let series = Series(id: id, seriesId: 0, name: name, categoryId: categoryId)
        series.lastWatchedDate = lastWatchedDate
        series.isFavorite = isFavorite
        series.favoriteOrder = favoriteOrder
        return series
    }

    private func makeStream(id: String, name: String = "Stream", lastWatchedDate: Date? = nil, isFavorite: Bool = false, favoriteOrder: Int? = nil, categoryId: String? = nil) -> LiveStream {
        let stream = LiveStream(id: id, streamId: 0, name: name, categoryId: categoryId)
        stream.lastWatchedDate = lastWatchedDate
        stream.isFavorite = isFavorite
        stream.favoriteOrder = favoriteOrder
        return stream
    }

    // MARK: - HomeDerivedContent Tests

    @Test func `recently watched presence returns false when all collections are empty`() {
        let scope = HomeDerivedScope(playlistPrefix: nil, restriction: ContentRestriction())
        let hasWatched = HomeDerivedContent.hasRecentlyWatched(
            movies: [],
            series: [],
            streams: [],
            includeLiveTV: true,
            scope: scope
        )
        #expect(!hasWatched)

        let items = HomeDerivedContent.recentlyWatched(
            movies: [],
            series: [],
            streams: [],
            includeLiveTV: true,
            scope: scope
        )
        #expect(items.isEmpty)
    }

    @Test func `recently watched detects watched movies and respects playlist scope`() {
        let now = Date()
        let matchingMovie = makeMovie(id: "p1-m1", lastWatchedDate: now)
        let otherMovie = makeMovie(id: "p2-m2", lastWatchedDate: now)

        let p1Scope = HomeDerivedScope(playlistPrefix: "p1-", restriction: ContentRestriction())
        let p2Scope = HomeDerivedScope(playlistPrefix: "p2-", restriction: ContentRestriction())
        let p3Scope = HomeDerivedScope(playlistPrefix: "p3-", restriction: ContentRestriction())

        #expect(HomeDerivedContent.hasRecentlyWatched(movies: [matchingMovie], series: [], streams: [], includeLiveTV: false, scope: p1Scope))
        #expect(!HomeDerivedContent.hasRecentlyWatched(movies: [matchingMovie], series: [], streams: [], includeLiveTV: false, scope: p2Scope))
        #expect(HomeDerivedContent.hasRecentlyWatched(movies: [matchingMovie, otherMovie], series: [], streams: [], includeLiveTV: false, scope: p2Scope))
        #expect(!HomeDerivedContent.hasRecentlyWatched(movies: [matchingMovie, otherMovie], series: [], streams: [], includeLiveTV: false, scope: p3Scope))
    }

    @Test func `recently watched includes live streams only when enabled`() {
        let now = Date()
        let stream = makeStream(id: "s1", lastWatchedDate: now)
        let scope = HomeDerivedScope(playlistPrefix: nil, restriction: ContentRestriction())

        #expect(!HomeDerivedContent.hasRecentlyWatched(movies: [], series: [], streams: [stream], includeLiveTV: false, scope: scope))
        #expect(HomeDerivedContent.hasRecentlyWatched(movies: [], series: [], streams: [stream], includeLiveTV: true, scope: scope))

        let withoutLive = HomeDerivedContent.recentlyWatched(movies: [], series: [], streams: [stream], includeLiveTV: false, scope: scope)
        let withLive = HomeDerivedContent.recentlyWatched(movies: [], series: [], streams: [stream], includeLiveTV: true, scope: scope)
        #expect(withoutLive.isEmpty)
        #expect(withLive.count == 1)
    }

    @Test func `recently watched and favorites hide restricted categories`() {
        let now = Date()
        let restrictedMovie = makeMovie(id: "m-adult", name: "Adult Film", lastWatchedDate: now, isFavorite: true, categoryId: "adult")
        let allowedMovie = makeMovie(id: "m-kids", name: "Family Film", lastWatchedDate: now, isFavorite: true, categoryId: "kids")

        let unrestricted = ContentRestriction()
        let restricted = ContentRestriction(isActive: true, restrictedCategoryIDs: ["adult"], hiddenCategoryIDs: [])

        let unresScope = HomeDerivedScope(playlistPrefix: nil, restriction: unrestricted)
        let resScope = HomeDerivedScope(playlistPrefix: nil, restriction: restricted)

        // Only restricted movie:
        #expect(HomeDerivedContent.hasRecentlyWatched(movies: [restrictedMovie], series: [], streams: [], includeLiveTV: false, scope: unresScope))
        #expect(!HomeDerivedContent.hasRecentlyWatched(movies: [restrictedMovie], series: [], streams: [], includeLiveTV: false, scope: resScope))

        #expect(HomeDerivedContent.hasFavorites(movies: [restrictedMovie], series: [], streams: [], scope: unresScope))
        #expect(!HomeDerivedContent.hasFavorites(movies: [restrictedMovie], series: [], streams: [], scope: resScope))

        // Both movies:
        #expect(HomeDerivedContent.hasRecentlyWatched(movies: [restrictedMovie, allowedMovie], series: [], streams: [], includeLiveTV: false, scope: resScope))
        #expect(HomeDerivedContent.hasFavorites(movies: [restrictedMovie, allowedMovie], series: [], streams: [], scope: resScope))

        let resWatched = HomeDerivedContent.recentlyWatched(movies: [restrictedMovie, allowedMovie], series: [], streams: [], includeLiveTV: false, scope: resScope)
        let resFavorites = HomeDerivedContent.favorites(movies: [restrictedMovie, allowedMovie], series: [], streams: [], scope: resScope)
        #expect(resWatched.map(\.id) == ["movie-m-kids"])
        #expect(resFavorites.map(\.id) == ["movie-m-kids"])
    }

    @Test func `favorites preserves ordering across streams movies and series`() {
        let stream = makeStream(id: "ch-1", name: "Channel 1", isFavorite: true, favoriteOrder: 2)
        let movie = makeMovie(id: "mv-1", name: "Alpha", isFavorite: true, favoriteOrder: 0)
        let series = makeSeries(id: "sr-1", name: "Show A", isFavorite: true, favoriteOrder: 1)
        let unorderedMovie = makeMovie(id: "mv-2", name: "Beta", isFavorite: true, favoriteOrder: nil)

        let scope = HomeDerivedScope(playlistPrefix: nil, restriction: ContentRestriction())
        #expect(HomeDerivedContent.hasFavorites(movies: [movie, unorderedMovie], series: [series], streams: [stream], scope: scope))

        let favorites = HomeDerivedContent.favorites(movies: [movie, unorderedMovie], series: [series], streams: [stream], scope: scope)
        let ids = favorites.map(\.id)
        #expect(ids == ["movie-mv-1", "series-sr-1", "live-ch-1", "movie-mv-2"])
    }

    @Test func `empty presence check is strictly equivalent to full rail isEmpty`() {
        let now = Date()
        let movies = [
            makeMovie(id: "p1-m1", lastWatchedDate: now.addingTimeInterval(-100), isFavorite: true, categoryId: "cat1"),
            makeMovie(id: "p2-m2", lastWatchedDate: now, isFavorite: false, categoryId: "cat2")
        ]
        let series = [
            makeSeries(id: "p1-s1", lastWatchedDate: now.addingTimeInterval(-50), isFavorite: false, categoryId: "cat1")
        ]
        let streams = [
            makeStream(id: "p1-st1", isFavorite: true, categoryId: "catHidden")
        ]

        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["catHidden"], hiddenCategoryIDs: [])
        let scope = HomeDerivedScope(playlistPrefix: "p1-", restriction: restriction)

        let hasWatched = HomeDerivedContent.hasRecentlyWatched(movies: movies, series: series, streams: streams, includeLiveTV: false, scope: scope)
        let watchedItems = HomeDerivedContent.recentlyWatched(movies: movies, series: series, streams: streams, includeLiveTV: false, scope: scope)
        #expect(hasWatched == !watchedItems.isEmpty)

        let hasFavs = HomeDerivedContent.hasFavorites(movies: movies, series: series, streams: streams, scope: scope)
        let favItems = HomeDerivedContent.favorites(movies: movies, series: series, streams: streams, scope: scope)
        #expect(hasFavs == !favItems.isEmpty)
    }

    // MARK: - TVHeroModel Tests

    @Test func `TVHeroModel advances on tick when unpaused and dwells correctly`() {
        let model = TVHeroModel()
        let item1 = HeroItem.movie(makeMovie(id: "h1", name: "Hero 1"), backdropURL: nil, overview: "O1")
        let item2 = HeroItem.movie(makeMovie(id: "h2", name: "Hero 2"), backdropURL: nil, overview: "O2")
        model.configure(items: [item1, item2])

        #expect(model.currentIndex == 0)
        #expect(model.progress == 0)
        #expect(!model.isPaused)

        // Multiple ticks increment progress without paging
        for _ in 1 ... 10 {
            let shouldPage = model.tickAutoAdvance()
            #expect(!shouldPage)
            #expect(model.progress > 0)
        }

        // Ticking until completion triggers advance
        var didAdvance = false
        var ticks = 0
        while ticks < 200, !didAdvance {
            ticks += 1
            if model.tickAutoAdvance() {
                model.advance()
                didAdvance = true
            }
        }
        #expect(didAdvance)
        #expect(model.currentIndex == 1)
        #expect(model.progress == 0)
    }

    @Test func `TVHeroModel holds progress at zero and does not page when paused`() {
        let model = TVHeroModel()
        let item1 = HeroItem.movie(makeMovie(id: "h1", name: "Hero 1"), backdropURL: nil, overview: "O1")
        let item2 = HeroItem.movie(makeMovie(id: "h2", name: "Hero 2"), backdropURL: nil, overview: "O2")
        model.configure(items: [item1, item2])

        // Advance progress a bit
        _ = model.tickAutoAdvance()
        _ = model.tickAutoAdvance()
        #expect(model.progress > 0)

        // Pausing immediately resets progress to 0
        model.isPaused = true
        #expect(model.progress == 0)

        // Subsequent ticks while paused return false and keep progress at 0 without redundant writes
        for _ in 1 ... 50 {
            let shouldPage = model.tickAutoAdvance()
            #expect(!shouldPage)
            #expect(model.progress == 0)
            #expect(model.currentIndex == 0)
        }

        // Resuming starts from 0 progress ensuring full dwell on the current slide
        model.isPaused = false
        #expect(model.progress == 0)
        _ = model.tickAutoAdvance()
        #expect(model.progress > 0)
        #expect(model.currentIndex == 0)
    }
}

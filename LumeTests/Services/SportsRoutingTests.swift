//
//  SportsRoutingTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SportsRoutingTests {
    private func catalog() throws -> ModelContext {
        let context = try ModelContext(makeTestContainer())
        for (id, ref) in [("m-ordinary", nil), ("m-sports", "sportarr://ev-123456")] {
            let movie = Movie(id: id, streamId: 0, name: id)
            movie.categoryId = "mixed"
            movie.sportsRef = ref
            context.insert(movie)
        }
        // A league with its games loaded, a league still a shell, an ordinary show.
        for (id, ref, hasGame) in [("s-league", "sportarr://lg-000032", true), ("s-shell", "sportarr://lg-000033", false), ("s-ordinary", nil, false)] {
            let series = Series(id: id, seriesId: 0, name: id)
            series.categoryId = "mixed"
            series.sportsRef = ref
            context.insert(series)
            if hasGame {
                let game = Episode(id: id + "-e", episodeId: "e", title: "Lions at Patriots", containerExtension: "mkv", seasonNum: 1, episodeNum: 1)
                context.insert(game)
                game.series = series
            }
        }
        let league = Series(id: "s-only", seriesId: 0, name: "NFL")
        league.categoryId = "sports"
        league.sportsRef = "sportarr://lg-000032"
        context.insert(league)
        let game = Episode(id: "s-only-e", episodeId: "e", title: "Bears at Packers", containerExtension: "mkv", seasonNum: 1, episodeNum: 1)
        context.insert(game)
        game.series = league
        try context.save()
        return context
    }

    @Test func `category grids are untouched while sports are not routed`() throws {
        let context = try catalog()
        #expect(try context.fetchCount(CategoryGridQuery.movies(categoryId: "mixed", grouped: false)) == 2)
        #expect(try context.fetchCount(CategoryGridQuery.series(categoryId: "mixed", grouped: false)) == 3)
    }

    @Test func `routed sports leave the grids and a league without games stays reachable`() throws {
        let context = try catalog()
        let movies = try context.fetch(CategoryGridQuery.movies(categoryId: "mixed", grouped: false, routesSports: true))
        let series = try context.fetch(CategoryGridQuery.series(categoryId: "mixed", grouped: false, routesSports: true))
        #expect(movies.map(\.id) == ["m-ordinary"])
        #expect(Set(series.map(\.id)) == ["s-ordinary", "s-shell"])
    }

    @Test func `only a category holding nothing but routed sports loses its row`() throws {
        let context = try catalog()
        #expect(SportsReplayLibrary.routedCategories(for: .series, in: context) == ["sports"])
        #expect(SportsReplayLibrary.routedCategories(for: .movies, in: context).isEmpty)
    }

    /// One playlist's worth of discovery rows: an ordinary title and a sports
    /// one of each kind, both recently added and both in the same genre.
    private func discovery() throws -> (ModelContainer, CatalogScope) {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = UUID()
        let prefix = CatalogScope.prefix(playlist)
        for (name, ref) in [("ordinary", nil), ("sports", "sportarr://ev-123456")] {
            let movie = Movie(id: prefix + "m-" + name, streamId: 0, name: name)
            movie.added = "1"
            movie.genre = "Sport"
            movie.sportsRef = ref
            context.insert(movie)
        }
        for (name, ref) in [("ordinary", nil), ("league", "sportarr://lg-000032")] {
            let series = Series(id: prefix + "s-" + name, seriesId: 0, name: name)
            series.lastModified = "1"
            series.genre = "Sport"
            series.sportsRef = ref
            context.insert(series)
            let episode = Episode(id: prefix + "e-" + name, episodeId: "e", title: name, containerExtension: "mkv", seasonNum: 1, episodeNum: 1)
            context.insert(episode)
            episode.series = series
        }
        try context.save()
        return (container, .isolated(playlist))
    }

    @Test func `recently added drops routed sports while watched and favourite rows keep them`() throws {
        let (container, scope) = try discovery()
        let context = ModelContext(container)
        #expect(try context.fetchCount(MovieCollectionQuery.rowDescriptor(for: .recentlyAdded, scope: scope)) == 2)
        #expect(try context.fetchCount(MovieCollectionQuery.rowDescriptor(for: .recentlyAdded, scope: scope, routesSports: true)) == 1)
        #expect(try context.fetchCount(SeriesCollectionQuery.gridDescriptor(for: .recentlyAdded, scope: scope, routesSports: true)) == 1)
        for movie in try context.fetch(FetchDescriptor<Movie>()) {
            movie.isFavorite = true
        }
        try context.save()
        #expect(try context.fetchCount(MovieCollectionQuery.rowDescriptor(for: .favorites, scope: scope, routesSports: true)) == 2)
    }

    @Test func `genre pages and the genre list drop routed sports`() async throws {
        let (container, scope) = try discovery()
        func request(_ routes: Bool) -> GenrePageRequest {
            GenrePageRequest(genre: "Sport", scope: scope, excludedCategoryIDs: [], offset: 0, pageSize: 20, routesSports: routes)
        }
        #expect(GenrePageFetcher.movies(container: container, request: request(false), sortBy: []).ids.count == 2)
        #expect(GenrePageFetcher.movies(container: container, request: request(true), sortBy: []).ids.count == 1)
        #expect(GenrePageFetcher.series(container: container, request: request(true), sortBy: []).ids.count == 1)
        // With only sports in the genre, routing removes the genre itself.
        let context = ModelContext(container)
        for movie in try context.fetch(FetchDescriptor<Movie>()) where movie.sportsRef == nil {
            context.delete(movie)
        }
        try context.save()
        #expect(await GenreDerivation.movieGenres(in: container, scope: scope, restriction: ContentRestriction()) == ["Sport"])
        #expect(await GenreDerivation.movieGenres(in: container, scope: scope, restriction: ContentRestriction(), routesSports: true).isEmpty)
    }
}

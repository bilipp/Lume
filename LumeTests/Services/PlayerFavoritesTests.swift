import Foundation
@testable import Lume
import SwiftData
import Testing

struct PlayerFavoritesTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Movie.self, Series.self, Episode.self, LiveStream.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - isFavorite

    @Test func `isFavorite for movie returns false by default`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "m-1", streamId: 1, name: "Test")
        context.insert(movie)
        try context.save()

        #expect(!PlayerFavorites.isFavorite(for: .movie("m-1"), in: context))
    }

    @Test func `isFavorite for movie returns true when favorited`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "m-2", streamId: 2, name: "Test")
        movie.isFavorite = true
        context.insert(movie)
        try context.save()

        #expect(PlayerFavorites.isFavorite(for: .movie("m-2"), in: context))
    }

    @Test func `isFavorite for episode delegates to series`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "s-1", seriesId: 1, name: "Test Series")
        series.isFavorite = true
        context.insert(series)
        let episode = Episode(id: "e-1", episodeId: "1", title: "Ep 1", containerExtension: "mp4", seasonNum: 1, episodeNum: 1, series: series)
        context.insert(episode)
        try context.save()

        #expect(PlayerFavorites.isFavorite(for: .episode("e-1"), in: context))
    }

    @Test func `isFavorite for episode returns false when series not favorited`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "s-2", seriesId: 2, name: "Test Series")
        context.insert(series)
        let episode = Episode(id: "e-2", episodeId: "2", title: "Ep 2", containerExtension: "mp4", seasonNum: 1, episodeNum: 1, series: series)
        context.insert(episode)
        try context.save()

        #expect(!PlayerFavorites.isFavorite(for: .episode("e-2"), in: context))
    }

    @Test func `isFavorite for live stream returns false by default`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let stream = LiveStream(id: "l-1", streamId: 1, name: "Channel")
        context.insert(stream)
        try context.save()

        #expect(!PlayerFavorites.isFavorite(for: .live("l-1"), in: context))
    }

    @Test func `isFavorite for live stream returns true when favorited`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let stream = LiveStream(id: "l-2", streamId: 2, name: "Channel")
        stream.isFavorite = true
        context.insert(stream)
        try context.save()

        #expect(PlayerFavorites.isFavorite(for: .live("l-2"), in: context))
    }

    // MARK: - toggle

    @Test func `toggle movie flips isFavorite`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "m-3", streamId: 3, name: "Test")
        context.insert(movie)
        try context.save()

        let newState = PlayerFavorites.toggle(for: .movie("m-3"), in: context)
        #expect(newState)
        #expect(movie.isFavorite)
    }

    @Test func `toggle movie twice returns to unfavorited`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "m-4", streamId: 4, name: "Test")
        context.insert(movie)
        try context.save()

        _ = PlayerFavorites.toggle(for: .movie("m-4"), in: context)
        let newState = PlayerFavorites.toggle(for: .movie("m-4"), in: context)
        #expect(!newState)
        #expect(!movie.isFavorite)
    }

    @Test func `toggle movie sets addedToWatchlistDate`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "m-5", streamId: 5, name: "Test")
        context.insert(movie)
        try context.save()

        _ = PlayerFavorites.toggle(for: .movie("m-5"), in: context)
        #expect(movie.addedToWatchlistDate != nil)
    }

    @Test func `toggle movie clears addedToWatchlistDate when unfavorited`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "m-6", streamId: 6, name: "Test")
        movie.isFavorite = true
        movie.addedToWatchlistDate = Date()
        context.insert(movie)
        try context.save()

        _ = PlayerFavorites.toggle(for: .movie("m-6"), in: context)
        #expect(movie.addedToWatchlistDate == nil)
    }

    @Test func `toggle episode delegates to series`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "s-3", seriesId: 3, name: "Test Series")
        context.insert(series)
        let episode = Episode(id: "e-3", episodeId: "3", title: "Ep 3", containerExtension: "mp4", seasonNum: 1, episodeNum: 1, series: series)
        context.insert(episode)
        try context.save()

        let newState = PlayerFavorites.toggle(for: .episode("e-3"), in: context)
        #expect(newState)
        #expect(series.isFavorite)
        #expect(series.addedToWatchlistDate != nil)
    }

    @Test func `toggle live stream flips isFavorite`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let stream = LiveStream(id: "l-3", streamId: 3, name: "Channel")
        context.insert(stream)
        try context.save()

        let newState = PlayerFavorites.toggle(for: .live("l-3"), in: context)
        #expect(newState)
        #expect(stream.isFavorite)
    }

    @Test func `toggle live stream twice returns to unfavorited`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let stream = LiveStream(id: "l-4", streamId: 4, name: "Channel")
        context.insert(stream)
        try context.save()

        _ = PlayerFavorites.toggle(for: .live("l-4"), in: context)
        let newState = PlayerFavorites.toggle(for: .live("l-4"), in: context)
        #expect(!newState)
        #expect(!stream.isFavorite)
    }
}

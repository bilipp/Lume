import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct StorageManagerTests {
    @Test func `gatherStats counts every catalog type`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        context.insert(Movie(id: "m1", streamId: 1, name: "A"))
        context.insert(Movie(id: "m2", streamId: 2, name: "B"))
        let show = Series(id: "s1", seriesId: 1, name: "Show")
        context.insert(show)
        context.insert(Episode(
            id: "e1", episodeId: "1", title: "Pilot", containerExtension: "mkv",
            seasonNum: 1, episodeNum: 1, series: show
        ))
        context.insert(LiveStream(id: "c1", streamId: 1, name: "Channel"))
        try context.save()

        let stats = await StorageManager.gatherStats(in: context)

        #expect(stats.movieCount == 2)
        #expect(stats.seriesCount == 1)
        #expect(stats.episodeCount == 1)
        #expect(stats.channelCount == 1)
    }

    @Test func `clearMetadataEnrichment resets enrichment but keeps the title`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let movie = Movie(id: "m1", streamId: 1, name: "Keep Me")
        movie.backdropPath = "/backdrop.jpg"
        movie.logoPath = "/logo.png"
        movie.tagline = "A tagline"
        movie.contentRating = "PG-13"
        movie.tmdbEnrichedAt = Date(timeIntervalSince1970: 1)
        movie.similarTMDBIds = [1, 2, 3]
        movie.trailers = [TitleVideo(key: "abc", name: "Trailer", type: "Trailer")]
        movie.imdbId = "tt1234567"
        movie.externalRatings = [ExternalRating(source: .imdb, value: "8.0/10")]
        movie.ratingsEnrichedAt = Date(timeIntervalSince1970: 1)
        movie.collectionId = 99
        movie.collectionName = "Series Collection"
        movie.isFavorite = true
        movie.watchProgress = 0.4
        context.insert(movie)
        context.insert(CastMember(id: "m1-cast-0", tmdbPersonId: 5, name: "Actor", order: 0, movie: movie))
        try context.save()

        StorageManager.clearMetadataEnrichment(in: context)

        let refetched = try #require(
            try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == "m1" })).first
        )
        // Title and user data survive.
        #expect(refetched.name == "Keep Me")
        #expect(refetched.isFavorite == true)
        #expect(refetched.watchProgress == 0.4)
        // Enrichment is gone.
        #expect(refetched.backdropPath == nil)
        #expect(refetched.logoPath == nil)
        #expect(refetched.tagline == nil)
        #expect(refetched.contentRating == nil)
        #expect(refetched.tmdbEnrichedAt == nil)
        #expect(refetched.similarTMDBIds.isEmpty)
        #expect(refetched.trailers.isEmpty)
        #expect(refetched.imdbId == nil)
        #expect(refetched.externalRatings.isEmpty)
        #expect(refetched.ratingsEnrichedAt == nil)
        #expect(refetched.collectionId == nil)
        #expect(refetched.collectionName == nil)
        #expect(refetched.castMembers.isEmpty)

        let remainingCast = try context.fetch(FetchDescriptor<CastMember>())
        #expect(remainingCast.isEmpty)
    }
}

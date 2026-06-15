import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct GenreDerivationTests {
    private let prefix = "11111111-1111-1111-1111-111111111111-"
    private let otherPrefix = "22222222-2222-2222-2222-222222222222-"

    private func makeMovie(streamId: Int, genre: String?, prefix: String) -> Movie {
        let movie = Movie(id: "\(prefix)movie-\(streamId)", streamId: streamId, name: "Movie \(streamId)")
        movie.genre = genre
        return movie
    }

    private func makeSeries(seriesId: Int, genre: String?, prefix: String) -> Series {
        Series(id: "\(prefix)series-\(seriesId)", seriesId: seriesId, name: "Series \(seriesId)", genre: genre)
    }

    @Test func `derives distinct movie genres for the active playlist, most-common first`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        context.insert(makeMovie(streamId: 1, genre: "Action, Drama", prefix: prefix))
        context.insert(makeMovie(streamId: 2, genre: "Action, Comedy", prefix: prefix))
        context.insert(makeMovie(streamId: 3, genre: "Action", prefix: prefix))
        context.insert(makeMovie(streamId: 4, genre: nil, prefix: prefix))
        // A different playlist's movie must not leak into the result.
        context.insert(makeMovie(streamId: 5, genre: "Horror", prefix: otherPrefix))

        let genres = GenreDerivation.movieGenres(in: context, playlistPrefix: prefix, restriction: ContentRestriction())
        #expect(genres == ["Action", "Comedy", "Drama"])
    }

    @Test func `derives distinct series genres for the active playlist`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        context.insert(makeSeries(seriesId: 1, genre: "Sci-Fi & Fantasy, Drama", prefix: prefix))
        context.insert(makeSeries(seriesId: 2, genre: "Drama", prefix: prefix))
        context.insert(makeSeries(seriesId: 3, genre: "Horror", prefix: otherPrefix))

        let genres = GenreDerivation.seriesGenres(in: context, playlistPrefix: prefix, restriction: ContentRestriction())
        #expect(genres == ["Drama", "Sci-Fi & Fantasy"])
    }

    @Test func `is empty when no title in the playlist carries a genre`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        context.insert(makeMovie(streamId: 1, genre: nil, prefix: prefix))

        #expect(GenreDerivation.movieGenres(in: context, playlistPrefix: prefix, restriction: ContentRestriction()).isEmpty)
    }
}

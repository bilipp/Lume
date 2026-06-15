import Foundation
@testable import Lume
import SwiftData
import Testing

/// TMDB is the primary genre source; the provider (playlist) genre is only a
/// fallback shown until enrichment runs. These lock in that precedence across the
/// provider-fallback rule and the TMDB-enrichment write paths.
@MainActor
struct GenrePrecedenceTests {
    private func tmdbDetails(genreNames: [String]) -> TMDBTitleDetails {
        TMDBTitleDetails(genreNames: genreNames, cast: [], similarIDs: [], videos: [])
    }

    // MARK: - Provider fallback rule

    @Test func `provider genre seeds an unset genre`() {
        #expect(GenreParser.providerFallback(current: nil, provider: "Drama") == "Drama")
        #expect(GenreParser.providerFallback(current: "", provider: "Drama") == "Drama")
    }

    @Test func `provider genre never overwrites an existing genre`() {
        // A genre TMDB already set must survive a later provider sync.
        #expect(GenreParser.providerFallback(current: "Action", provider: "Drama") == "Action")
    }

    @Test func `provider fallback leaves genre unset when neither side has a value`() {
        #expect(GenreParser.providerFallback(current: nil, provider: nil) == nil)
        #expect(GenreParser.providerFallback(current: nil, provider: "") == nil)
    }

    // MARK: - TMDB overwrites (primary source)

    @Test func `TMDB genre overwrites the provider genre on a series`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show", genre: "Drama")
        context.insert(series)
        applySeriesDetails(tmdbDetails(genreNames: ["Action", "Thriller"]), to: series, context: context, includeCast: false)
        #expect(series.genre == "Action, Thriller")
    }

    @Test func `series provider genre survives when TMDB supplies none`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show", genre: "Drama")
        context.insert(series)
        applySeriesDetails(tmdbDetails(genreNames: []), to: series, context: context, includeCast: false)
        #expect(series.genre == "Drama")
    }

    @Test func `TMDB genre overwrites a movie's stale genre`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let movie = Movie(id: "p-movie-1", streamId: 1, name: "Film")
        movie.genre = "Stale"
        context.insert(movie)
        applyMovieDetails(tmdbDetails(genreNames: ["Action"]), to: movie, context: context, includeCast: false)
        #expect(movie.genre == "Action")
    }
}

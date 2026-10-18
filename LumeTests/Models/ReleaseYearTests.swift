import Foundation
@testable import Lume
import SwiftData
import Testing

/// The detail screens show a release year. Xtream and M3U VOD lists carry no
/// release date, so it comes from TMDB enrichment, or from a "(2010)" in the
/// provider's name until enrichment has run.
@MainActor
struct ReleaseYearTests {
    private func tmdbDetails(releaseDate: String?) -> TMDBTitleDetails {
        TMDBTitleDetails(releaseDate: releaseDate, genreNames: [], cast: [], similarIDs: [], videos: [])
    }

    // MARK: - Display fallback

    @Test func `release date wins over a year in the name`() {
        #expect(DetailFormat.year(releaseDate: "2010-07-16", name: "Inception (2009)") == "2010")
    }

    @Test func `parenthesized year in the name fills a missing release date`() {
        #expect(DetailFormat.year(releaseDate: nil, name: "DE | Der Pate (1972) 4K") == "1972")
        #expect(DetailFormat.year(releaseDate: "", name: "Inception (2010)") == "2010")
    }

    @Test func `last parenthesized year is the release year`() {
        #expect(DetailFormat.year(releaseDate: nil, name: "Blade Runner 2049 (2017)") == "2017")
    }

    @Test func `bare number in the name is not a release year`() {
        #expect(DetailFormat.year(releaseDate: nil, name: "Blade Runner 2049") == nil)
        #expect(DetailFormat.year(releaseDate: nil, name: "Wonder Woman 1984") == nil)
        #expect(DetailFormat.year(releaseDate: nil, name: "Inception") == nil)
    }

    // MARK: - TMDB enrichment

    @Test func `TMDB fills a movie with no release date`() throws {
        let container = try makeTestContainer()
        let movie = Movie(id: "p-movie-1", streamId: 1, name: "Film")
        container.mainContext.insert(movie)
        applyMovieDetails(tmdbDetails(releaseDate: "2010-07-16"), to: movie, context: container.mainContext, includeCast: false)
        #expect(movie.releaseDate == "2010-07-16")
    }

    @Test func `TMDB replaces a provider date with no year`() throws {
        let container = try makeTestContainer()
        let movie = Movie(id: "p-movie-1", streamId: 1, name: "Film")
        movie.releaseDate = "N/A"
        container.mainContext.insert(movie)
        applyMovieDetails(tmdbDetails(releaseDate: "2010-07-16"), to: movie, context: container.mainContext, includeCast: false)
        #expect(movie.releaseDate == "2010-07-16")
    }

    @Test func `provider release date survives TMDB enrichment`() throws {
        let container = try makeTestContainer()
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show", releaseDate: "2008-01-20")
        container.mainContext.insert(series)
        applySeriesDetails(tmdbDetails(releaseDate: "2008-02-01"), to: series, context: container.mainContext, includeCast: false)
        #expect(series.releaseDate == "2008-01-20")
    }

    @Test func `TMDB fills a series with no release date`() throws {
        let container = try makeTestContainer()
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        container.mainContext.insert(series)
        applySeriesDetails(tmdbDetails(releaseDate: "2008-01-20"), to: series, context: container.mainContext, includeCast: false)
        #expect(series.releaseDate == "2008-01-20")
    }
}

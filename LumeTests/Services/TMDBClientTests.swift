import Foundation
@testable import Lume
import Testing

struct TMDBClientTests {
    // MARK: - isConfigured

    @Test func `not configured when token is nil`() {
        let client = TMDBClient(session: .shared, token: nil)
        #expect(client.isConfigured == false)
    }

    @Test func `not configured when token is empty`() {
        let client = TMDBClient(session: .shared, token: "")
        #expect(client.isConfigured == false)
    }

    @Test func `not configured when token is placeholder`() {
        let client = TMDBClient(session: .shared, token: "$(TMDBAccessToken)")
        #expect(client.isConfigured == false)
    }

    @Test func `configured when token is valid`() {
        let client = TMDBClient(session: .shared, token: "valid_token_123")
        #expect(client.isConfigured == true)
    }

    // MARK: - backdropURL

    @Test func `backdrop URL with path`() {
        let url = TMDBClient.backdropURL("/abc.jpg")
        #expect(url?.absoluteString == "https://image.tmdb.org/t/p/w1920/abc.jpg")
    }

    @Test func `backdrop URL with nil path`() {
        let url = TMDBClient.backdropURL(nil)
        #expect(url == nil)
    }

    @Test func `backdrop URL with empty path`() {
        let url = TMDBClient.backdropURL("")
        #expect(url == nil)
    }

    @Test func `backdrop URL custom size`() {
        let url = TMDBClient.backdropURL("/abc.jpg", size: "w500")
        #expect(url?.absoluteString == "https://image.tmdb.org/t/p/w500/abc.jpg")
    }

    // MARK: - profileURL

    @Test func `profile URL with path`() {
        let url = TMDBClient.profileURL("/def.jpg")
        #expect(url?.absoluteString == "https://image.tmdb.org/t/p/w185/def.jpg")
    }

    @Test func `profile URL with nil path`() {
        let url = TMDBClient.profileURL(nil)
        #expect(url == nil)
    }

    @Test func `profile URL custom size`() {
        let url = TMDBClient.profileURL("/def.jpg", size: "w45")
        #expect(url?.absoluteString == "https://image.tmdb.org/t/p/w45/def.jpg")
    }

    // MARK: - MediaType / TimeWindow

    @Test func `media type raw values`() {
        #expect(TMDBClient.MediaType.movie.rawValue == "movie")
        #expect(TMDBClient.MediaType.tvShow.rawValue == "tv")
    }

    @Test func `time window raw values`() {
        #expect(TMDBClient.TimeWindow.day.rawValue == "day")
        #expect(TMDBClient.TimeWindow.week.rawValue == "week")
    }

    // MARK: - TrendingTitle

    @Test func `trending title properties`() {
        let title = TrendingTitle(id: 1, title: "Test", overview: "Overview", backdropPath: "/backdrop.jpg")
        #expect(title.id == 1)
        #expect(title.title == "Test")
        #expect(title.overview == "Overview")
        #expect(title.backdropPath == "/backdrop.jpg")
    }

    @Test func `trending title empty title`() {
        let title = TrendingTitle(id: 1, title: "", overview: "", backdropPath: nil)
        #expect(title.title.isEmpty)
    }

    @Test func `trending title hashable`() {
        let titleA = TrendingTitle(id: 1, title: "A", overview: "", backdropPath: nil)
        let titleB = TrendingTitle(id: 1, title: "A", overview: "", backdropPath: nil)
        let titleC = TrendingTitle(id: 2, title: "C", overview: "", backdropPath: nil)
        #expect(titleA == titleB)
        #expect(titleA != titleC)
    }

    // MARK: - TMDBTitleDetails

    @Test func `tmdb title details defaults`() {
        let details = TMDBTitleDetails(
            backdropPath: nil,
            tagline: nil,
            overview: nil,
            voteAverage: nil,
            runtimeMinutes: nil,
            genreNames: [],
            contentRating: nil,
            cast: [],
            similarIDs: []
        )
        #expect(details.backdropPath == nil)
        #expect(details.tagline == nil)
        #expect(details.overview == nil)
        #expect(details.voteAverage == nil)
        #expect(details.runtimeMinutes == nil)
        #expect(details.genreNames.isEmpty)
        #expect(details.contentRating == nil)
        #expect(details.cast.isEmpty)
        #expect(details.similarIDs.isEmpty)
    }

    @Test func `tmdb title details with values`() {
        let cast = [TMDBCastMember(tmdbPersonId: 1, name: "Actor", character: "Role", profilePath: "/p.jpg", order: 0)]
        let details = TMDBTitleDetails(
            backdropPath: "/back.jpg",
            tagline: "Tagline",
            overview: "Overview",
            voteAverage: 7.5,
            runtimeMinutes: 120,
            genreNames: ["Action", "Drama"],
            contentRating: "PG-13",
            cast: cast,
            similarIDs: [10, 20, 30]
        )
        #expect(details.backdropPath == "/back.jpg")
        #expect(details.tagline == "Tagline")
        #expect(details.voteAverage == 7.5)
        #expect(details.runtimeMinutes == 120)
        #expect(details.genreNames == ["Action", "Drama"])
        #expect(details.cast.count == 1)
        #expect(details.similarIDs == [10, 20, 30])
    }

    // MARK: - TMDBCastMember

    @Test func `tmdb cast member properties`() {
        let member = TMDBCastMember(
            tmdbPersonId: 123,
            name: "Actor Name",
            character: "Character Name",
            profilePath: "/profile.jpg",
            order: 1
        )
        #expect(member.tmdbPersonId == 123)
        #expect(member.name == "Actor Name")
        #expect(member.character == "Character Name")
        #expect(member.profilePath == "/profile.jpg")
        #expect(member.order == 1)
    }

    @Test func `tmdb cast member nil character`() {
        let member = TMDBCastMember(tmdbPersonId: 1, name: "Actor", character: nil, profilePath: nil, order: 0)
        #expect(member.character == nil)
        #expect(member.profilePath == nil)
    }

    @Test func `tmdb cast member hashable`() {
        let memberA = TMDBCastMember(tmdbPersonId: 1, name: "A", character: nil, profilePath: nil, order: 0)
        let memberB = TMDBCastMember(tmdbPersonId: 1, name: "A", character: nil, profilePath: nil, order: 0)
        let memberC = TMDBCastMember(tmdbPersonId: 2, name: "B", character: nil, profilePath: nil, order: 0)
        #expect(memberA == memberB)
        #expect(memberA != memberC)
    }

    // MARK: - TMDBError

    @Test func `tmdb error is sendable`() {
        // Verify all TMDBError cases can be used across concurrency boundaries
        let errors: [TMDBError] = [.missingToken, .invalidURL, .invalidResponse]
        for error in errors {
            #expect(error is any Error)
        }
    }

    @Test func `tmdb error server error has code`() {
        let error = TMDBError.serverError(404)
        // Verify it's an error
        #expect(error is any Error)
    }
}

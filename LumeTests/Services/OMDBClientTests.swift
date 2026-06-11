import Foundation
@testable import Lume
import Testing

struct OMDBClientTests {
    // MARK: - isConfigured

    @Test func `not configured when key is nil`() {
        let client = OMDBClient(session: .shared, key: nil)
        #expect(client.isConfigured == false)
    }

    @Test func `not configured when key is empty`() {
        let client = OMDBClient(session: .shared, key: "")
        #expect(client.isConfigured == false)
    }

    @Test func `not configured when key is placeholder`() {
        let client = OMDBClient(session: .shared, key: "$(OMDBAPIKey)")
        #expect(client.isConfigured == false)
    }

    @Test func `configured when key is valid`() {
        let client = OMDBClient(session: .shared, key: "90413c02")
        #expect(client.isConfigured == true)
    }

    @Test func `ratings throws missingKey when unconfigured`() async {
        let client = OMDBClient(session: .shared, key: nil)
        await #expect(throws: OMDBError.self) {
            _ = try await client.ratings(imdbId: "tt3896198")
        }
    }

    // MARK: - Source mapping

    @Test func `source maps known OMDb labels`() {
        #expect(ExternalRating.Source(omdbSource: "Internet Movie Database") == .imdb)
        #expect(ExternalRating.Source(omdbSource: "Rotten Tomatoes") == .rottenTomatoes)
        #expect(ExternalRating.Source(omdbSource: "Metacritic") == .metacritic)
    }

    @Test func `source returns nil for unknown label`() {
        #expect(ExternalRating.Source(omdbSource: "Some Other Aggregator") == nil)
        #expect(ExternalRating.Source(omdbSource: "") == nil)
    }

    // MARK: - mapRatings

    @Test func `mapRatings keeps known sources in order`() {
        let entries = [
            OMDBRatingEntry(source: "Internet Movie Database", value: "7.6/10"),
            OMDBRatingEntry(source: "Rotten Tomatoes", value: "85%"),
            OMDBRatingEntry(source: "Metacritic", value: "67/100")
        ]
        let ratings = OMDBClient.mapRatings(entries)
        #expect(ratings.map(\.source) == [.imdb, .rottenTomatoes, .metacritic])
        #expect(ratings.map(\.value) == ["7.6/10", "85%", "67/100"])
    }

    @Test func `mapRatings drops unknown sources`() {
        let entries = [
            OMDBRatingEntry(source: "Internet Movie Database", value: "7.6/10"),
            OMDBRatingEntry(source: "Unknown Source", value: "42")
        ]
        let ratings = OMDBClient.mapRatings(entries)
        #expect(ratings.count == 1)
        #expect(ratings.first?.source == .imdb)
    }

    @Test func `mapRatings drops empty values`() {
        let entries = [OMDBRatingEntry(source: "Rotten Tomatoes", value: "")]
        #expect(OMDBClient.mapRatings(entries).isEmpty)
    }

    @Test func `mapRatings deduplicates by source keeping first`() {
        let entries = [
            OMDBRatingEntry(source: "Rotten Tomatoes", value: "85%"),
            OMDBRatingEntry(source: "Rotten Tomatoes", value: "12%")
        ]
        let ratings = OMDBClient.mapRatings(entries)
        #expect(ratings.count == 1)
        #expect(ratings.first?.value == "85%")
    }

    // MARK: - Response decoding

    @Test func `decodes ratings from a successful response`() throws {
        let json = Data(Self.sampleResponse.utf8)
        let decoded = try JSONDecoder().decode(OMDBResponse.self, from: json)
        #expect(decoded.response == "True")
        #expect(decoded.ratings?.count == 3)

        let ratings = OMDBClient.mapRatings(decoded.ratings ?? [])
        #expect(ratings.map(\.source) == [.imdb, .rottenTomatoes, .metacritic])
        #expect(ratings.map(\.value) == ["7.6/10", "85%", "67/100"])
    }

    @Test func `decodes a not-found response`() throws {
        let json = Data(#"{ "Response": "False", "Error": "Incorrect IMDb ID." }"#.utf8)
        let decoded = try JSONDecoder().decode(OMDBResponse.self, from: json)
        #expect(decoded.response == "False")
        #expect(decoded.ratings == nil)
    }

    // MARK: - ExternalRating display

    @Test func `compact value strips denominator`() {
        #expect(ExternalRating(source: .imdb, value: "7.6/10").compactValue == "7.6")
        #expect(ExternalRating(source: .metacritic, value: "67/100").compactValue == "67")
        #expect(ExternalRating(source: .rottenTomatoes, value: "85%").compactValue == "85%")
    }

    @Test func `display names are the brand names`() {
        #expect(ExternalRating.Source.imdb.displayName == "IMDb")
        #expect(ExternalRating.Source.rottenTomatoes.displayName == "Rotten Tomatoes")
        #expect(ExternalRating.Source.metacritic.displayName == "Metacritic")
    }

    @Test func `external rating round-trips through Codable`() throws {
        let original = [
            ExternalRating(source: .imdb, value: "7.6/10"),
            ExternalRating(source: .rottenTomatoes, value: "85%")
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([ExternalRating].self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Fixtures

    private static let sampleResponse = """
    {
      "Title": "Guardians of the Galaxy: Vol. 2",
      "Ratings": [
        { "Source": "Internet Movie Database", "Value": "7.6/10" },
        { "Source": "Rotten Tomatoes", "Value": "85%" },
        { "Source": "Metacritic", "Value": "67/100" }
      ],
      "imdbID": "tt3896198",
      "Response": "True"
    }
    """
}

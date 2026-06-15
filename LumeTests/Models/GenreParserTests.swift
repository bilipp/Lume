import Foundation
@testable import Lume
import Testing

struct GenreParserTests {
    // MARK: - tokens(from:)

    @Test func `splits a comma-separated genre string`() {
        #expect(GenreParser.tokens(from: "Action, Sci-Fi, Thriller") == ["Action", "Sci-Fi", "Thriller"])
    }

    @Test func `splits on pipes and slashes too`() {
        #expect(GenreParser.tokens(from: "Action|Adventure / Comedy") == ["Action", "Adventure", "Comedy"])
    }

    @Test func `keeps multi-word genres joined by ampersand whole`() {
        #expect(GenreParser.tokens(from: "Sci-Fi & Fantasy, Drama") == ["Sci-Fi & Fantasy", "Drama"])
    }

    @Test func `trims whitespace and drops empty tokens`() {
        #expect(GenreParser.tokens(from: " Action ,, ,  Drama ") == ["Action", "Drama"])
    }

    @Test func `dedupes case-insensitively keeping first casing and order`() {
        #expect(GenreParser.tokens(from: "Action, action, ACTION, Drama") == ["Action", "Drama"])
    }

    @Test func `returns empty for nil or blank input`() {
        #expect(GenreParser.tokens(from: nil).isEmpty)
        #expect(GenreParser.tokens(from: "   ").isEmpty)
    }

    // MARK: - contains(_:genre:)

    @Test func `matches a whole token case-insensitively`() {
        #expect(GenreParser.contains("Action, Sci-Fi", genre: "sci-fi"))
        #expect(GenreParser.contains("Drama", genre: "Drama"))
    }

    @Test func `does not match a substring of a token`() {
        // "Action" must not match within "Action & Adventure" treated as one token.
        #expect(!GenreParser.contains("Action & Adventure", genre: "Action"))
        #expect(!GenreParser.contains("Documentary", genre: "Drama"))
    }

    @Test func `does not match nil`() {
        #expect(!GenreParser.contains(nil, genre: "Action"))
    }

    // MARK: - distinctByFrequency(_:)

    @Test func `orders genres by frequency then alphabetically`() {
        let raws: [String?] = [
            "Action, Drama",
            "Action, Comedy",
            "Action",
            "Comedy",
            nil
        ]
        // Action: 3, Comedy: 2, Drama: 1 — frequency descending.
        #expect(GenreParser.distinctByFrequency(raws) == ["Action", "Comedy", "Drama"])
    }

    @Test func `breaks frequency ties alphabetically`() {
        let raws: [String?] = ["Western", "Adventure"]
        // Both appear once; alphabetical order wins.
        #expect(GenreParser.distinctByFrequency(raws) == ["Adventure", "Western"])
    }

    @Test func `is empty when no genres are present`() {
        #expect(GenreParser.distinctByFrequency([nil, "", "  "]).isEmpty)
    }
}

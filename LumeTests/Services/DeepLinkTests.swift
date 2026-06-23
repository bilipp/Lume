import Foundation
@testable import Lume
import Testing

struct DeepLinkTests {
    @Test func `parses movie link`() throws {
        let url = try #require(URL(string: "lume://movie/603"))
        #expect(DeepLink(url: url) == .movie(tmdbId: 603))
    }

    @Test func `parses series link`() throws {
        let url = try #require(URL(string: "lume://series/1396"))
        #expect(DeepLink(url: url) == .series(tmdbId: 1396))
    }

    @Test func `scheme is case insensitive`() throws {
        let url = try #require(URL(string: "LUME://MOVIE/42"))
        #expect(DeepLink(url: url) == .movie(tmdbId: 42))
    }

    @Test func `tolerates a trailing slash`() throws {
        let url = try #require(URL(string: "lume://series/77/"))
        #expect(DeepLink(url: url) == .series(tmdbId: 77))
    }

    @Test func `rejects a foreign scheme`() throws {
        let url = try #require(URL(string: "https://movie/603"))
        #expect(DeepLink(url: url) == nil)
    }

    @Test func `rejects an unknown kind`() throws {
        let url = try #require(URL(string: "lume://episode/603"))
        #expect(DeepLink(url: url) == nil)
    }

    @Test func `rejects a non-numeric id`() throws {
        let url = try #require(URL(string: "lume://movie/not-a-number"))
        #expect(DeepLink(url: url) == nil)
    }

    @Test func `rejects a missing id`() throws {
        let url = try #require(URL(string: "lume://movie"))
        #expect(DeepLink(url: url) == nil)
    }
}

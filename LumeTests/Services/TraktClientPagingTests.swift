import Foundation
@testable import Lume
import Testing

/// Serves canned Trakt collection pages and records the query each request
/// carried, so the walk can be asserted end to end.
private final nonisolated class TraktStubProtocol: URLProtocol {
    struct Endpoint {
        /// Response body per requested `page`.
        var pages: [Int: String]
        /// Page count reported back in `X-Pagination-Page-Count`.
        var pageCount: Int
        var requestedQueries: [[String: String]] = []
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var endpoints: [String: Endpoint] = [:]

    static func register(host: String, endpoint: Endpoint) {
        lock.withLock { endpoints[host] = endpoint }
    }

    static func requestedQueries(host: String) -> [[String: String]] {
        lock.withLock { endpoints[host]?.requestedQueries ?? [] }
    }

    // `URLProtocol` requires these as `class func` overrides — `static` can't
    // override.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let host = components.host ?? ""
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value
        }
        let page = Int(query["page"] ?? "") ?? 1

        let (body, pageCount) = Self.lock.withLock { () -> (String?, Int) in
            Self.endpoints[host]?.requestedQueries.append(query)
            let endpoint = Self.endpoints[host]
            return (endpoint?.pages[page], endpoint?.pageCount ?? 1)
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["X-Pagination-Page-Count": String(pageCount)]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "[]").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// Serialized: every test drives the same `api.trakt.tv` stub registration.
@MainActor
@Suite(.serialized)
struct TraktClientPagingTests {
    private func makeClient() -> TraktClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TraktStubProtocol.self]
        return TraktClient(
            session: URLSession(configuration: config),
            clientID: "test-client-id",
            clientSecret: "test-client-secret"
        )
    }

    /// A `/sync/watched/movies` page body carrying the given TMDB ids.
    private func moviePage(tmdbIDs: ClosedRange<Int>) -> String {
        let items = tmdbIDs
            .map { #"{"last_watched_at":"2026-01-0\#($0 % 9 + 1)T12:00:00.000Z","movie":{"ids":{"tmdb":\#($0)}}}"# }
            .joined(separator: ",")
        return "[\(items)]"
    }

    @Test func `watched movies walk every reported page`() async throws {
        TraktStubProtocol.register(host: "api.trakt.tv", endpoint: .init(
            pages: [
                1: moviePage(tmdbIDs: 1 ... 250),
                2: moviePage(tmdbIDs: 251 ... 500),
                3: moviePage(tmdbIDs: 501 ... 610)
            ],
            pageCount: 3
        ))

        let movies = try await makeClient().watchedMovies(accessToken: "token")

        #expect(movies.count == 610)
        #expect(movies.first?.movie.ids.tmdb == 1)
        #expect(movies.last?.movie.ids.tmdb == 610)

        let queries = TraktStubProtocol.requestedQueries(host: "api.trakt.tv")
        #expect(queries.count == 3)
        #expect(queries.map { $0["page"] } == ["1", "2", "3"])
        #expect(queries.allSatisfy { $0["limit"] == "250" })
    }

    @Test func `watched shows request season progress`() async throws {
        let body = """
        [{"show":{"ids":{"tmdb":300}},"seasons":[{"number":1,"episodes":[\
        {"number":1,"last_watched_at":"2026-01-02T12:00:00.000Z"}]}]}]
        """
        TraktStubProtocol.register(host: "api.trakt.tv", endpoint: .init(pages: [1: body], pageCount: 1))

        let shows = try await makeClient().watchedShows(accessToken: "token")

        #expect(shows.count == 1)
        #expect(shows.first?.seasons.first?.episodes.first?.number == 1)
        // Without `extended=progress` Trakt returns no season progress at all,
        // and that mode is capped at 100 items per page — asking for 250 would
        // make the reported page count disagree with the applied limit.
        let query = TraktStubProtocol.requestedQueries(host: "api.trakt.tv").first
        #expect(query?["extended"] == "progress")
        #expect(query?["limit"] == "100")
    }

    @Test func `a show without seasons decodes as no progress`() async throws {
        TraktStubProtocol.register(host: "api.trakt.tv", endpoint: .init(
            pages: [1: #"[{"plays":5,"show":{"ids":{"tmdb":300}},"aired_episodes":12}]"#],
            pageCount: 1
        ))

        let shows = try await makeClient().watchedShows(accessToken: "token")

        #expect(shows.count == 1)
        #expect(shows.first?.show.ids.tmdb == 300)
        #expect(shows.first?.seasons.isEmpty == true)
    }

    @Test func `the walk stops on an empty page`() async throws {
        TraktStubProtocol.register(host: "api.trakt.tv", endpoint: .init(
            pages: [1: moviePage(tmdbIDs: 1 ... 10), 2: "[]", 3: moviePage(tmdbIDs: 11 ... 20)],
            pageCount: 3
        ))

        let movies = try await makeClient().watchedMovies(accessToken: "token")

        #expect(movies.count == 10)
        #expect(TraktStubProtocol.requestedQueries(host: "api.trakt.tv").count == 2)
    }

    @Test func `watchlist keeps extended full while paging`() async throws {
        let page = #"[{"type":"movie","movie":{"title":"A","year":2020,"ids":{"tmdb":7}}}]"#
        TraktStubProtocol.register(host: "api.trakt.tv", endpoint: .init(
            pages: [1: page, 2: page],
            pageCount: 2
        ))

        let items = try await makeClient().watchlist(accessToken: "token")

        #expect(items.count == 2)
        let queries = TraktStubProtocol.requestedQueries(host: "api.trakt.tv")
        #expect(queries.count == 2)
        #expect(queries.allSatisfy { $0["extended"] == "full" })
    }
}

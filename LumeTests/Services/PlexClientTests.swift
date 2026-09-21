//
//  PlexClientTests.swift
//  LumeTests
//
//  The Plex wire layer: `MediaContainer` decoding, paging, the token-free
//  stream URL / token-bearing image URL split, and the playback auth the
//  header-less engine folds back into a query item.
//

import Foundation
@testable import Lume
import Testing

/// Serves canned Plex JSON per `host` + path, so the client under test never
/// touches the network. Registered only on the session handed to
/// `PlexClient`.
private final nonisolated class PlexStubProtocol: URLProtocol {
    struct Stub {
        var status: Int
        var body: String
        /// Echoed back so a test can assert what the client sent.
        var requiresToken: Bool = false
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [String: [String: Stub]] = [:]
    private nonisolated(unsafe) static var lastAcceptHeader: [String: String] = [:]

    static func register(host: String, path: String, stub: Stub) {
        lock.withLock { stubs[host, default: [:]][path] = stub }
    }

    static func acceptHeader(host: String) -> String? {
        lock.withLock { lastAcceptHeader[host] }
    }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let accept = request.value(forHTTPHeaderField: "Accept")
        let hasToken = request.value(forHTTPHeaderField: "X-Plex-Token") != nil
        Self.lock.withLock { Self.lastAcceptHeader[host] = accept }
        let stub = Self.lock.withLock { Self.stubs[host]?[url.path] } ?? Stub(status: 404, body: "")
        let status = stub.requiresToken && !hasToken ? 401 : stub.status
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct PlexClientTests {
    private func makeClient() -> PlexClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlexStubProtocol.self]
        return PlexClient(urlSession: URLSession(configuration: config))
    }

    private func server(_ host: String) -> URL {
        URL(string: "http://\(host):32400")!
    }

    private func failure(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch let error as PlexError {
            return error.logDescription
        } catch {
            return "unexpected \(error)"
        }
    }

    // MARK: - Probe

    @Test func `probe accepts a server that identifies itself`() async throws {
        let host = "plexprobeok.test"
        PlexStubProtocol.register(host: host, path: "/identity", stub: .init(status: 200, body: """
        {"MediaContainer": {"size": 0, "machineIdentifier": "05392f7b", "version": "1.43.4"}}
        """))

        try await makeClient().probe(server: server(host))
        // Plex serves XML unless JSON is asked for, so every request must.
        #expect(PlexStubProtocol.acceptHeader(host: host) == "application/json")
    }

    /// A `MediaContainer` with no `machineIdentifier` is not a Plex server —
    /// the field is what distinguishes it from any other JSON that happens to
    /// answer 200 at `/identity`.
    @Test func `probe rejects a container without a machine identifier`() async {
        let host = "plexprobebad.test"
        PlexStubProtocol.register(host: host, path: "/identity", stub: .init(status: 200, body: """
        {"MediaContainer": {"size": 0}}
        """))

        let result = await failure { try await makeClient().probe(server: server(host)) }
        #expect(result == PlexError.notAPlexServer.logDescription)
    }

    // MARK: - Sections

    @Test func `sections decode their key, title and type`() async throws {
        let host = "plexsections.test"
        PlexStubProtocol.register(host: host, path: "/library/sections", stub: .init(status: 200, body: """
        {"MediaContainer": {"size": 3, "Directory": [
          {"key": "1", "title": "Movies", "type": "movie"},
          {"key": "2", "title": "TV Shows", "type": "show"},
          {"key": "3", "title": "Music", "type": "artist"}
        ]}}
        """))

        let sections = try await makeClient().sections(server: server(host), token: "tok")
        #expect(sections.map(\.key) == ["1", "2", "3"])
        #expect(sections.map(\.type) == ["movie", "show", "artist"])
    }

    @Test func `a rejected token surfaces as unauthorized`() async {
        let host = "plexlocked.test"
        PlexStubProtocol.register(host: host, path: "/library/sections", stub: .init(status: 200, body: "{}", requiresToken: true))

        let result = await failure { _ = try await makeClient().sections(server: server(host), token: nil) }
        #expect(result == PlexError.unauthorized.logDescription)
    }

    // MARK: - Items

    @Test func `a movie page decodes metadata, part and guids`() async throws {
        let host = "plexmovies.test"
        PlexStubProtocol.register(host: host, path: "/library/sections/1/all", stub: .init(status: 200, body: """
        {"MediaContainer": {"size": 1, "totalSize": 42, "Metadata": [
          {"ratingKey": "1", "type": "movie", "title": "Arrival",
           "summary": "Linguist meets heptapods.", "year": 2016, "rating": 7.8,
           "audienceRating": 8.1, "duration": 8294507, "addedAt": 1789592930,
           "originallyAvailableAt": "2016-11-11", "thumb": "/library/metadata/1/thumb/17",
           "Media": [{"container": "mp4", "Part": [{"key": "/library/parts/1/17/file.mp4", "container": "mp4"}]}],
           "Genre": [{"tag": "Sci-Fi"}, {"tag": "Drama"}],
           "Guid": [{"id": "imdb://tt2543164"}, {"id": "tmdb://329865"}]}
        ]}}
        """))

        let page = try await makeClient().items(server: server(host), token: "tok", sectionKey: "1", type: PlexClient.movieType)
        #expect(page.totalSize == 42)
        let movie = try #require(page.items.first)
        #expect(movie.title == "Arrival")
        #expect(movie.durationSecs == 8294)
        #expect(movie.partKey == "/library/parts/1/17/file.mp4")
        #expect(movie.container == "mp4")
        #expect(movie.genreList == "Sci-Fi, Drama")
        #expect(movie.providerId("tmdb") == "329865")
        #expect(movie.providerId("imdb") == "tt2543164")
        #expect(movie.providerId("tvdb") == nil)
    }

    /// Plex omits `totalSize` when a query fits in one page, and the paging
    /// loop would never terminate if that read as zero-of-unknown.
    @Test func `a page without totalSize falls back to its own size`() async throws {
        let host = "plexonepage.test"
        PlexStubProtocol.register(host: host, path: "/library/sections/1/all", stub: .init(status: 200, body: """
        {"MediaContainer": {"size": 2, "Metadata": [
          {"ratingKey": "1", "type": "movie", "title": "One"},
          {"ratingKey": "2", "type": "movie", "title": "Two"}
        ]}}
        """))

        let page = try await makeClient().items(server: server(host), token: nil, sectionKey: "1", type: PlexClient.movieType)
        #expect(page.totalSize == 2)
    }

    @Test func `an episode page decodes its show and numbering`() async throws {
        let host = "plexeps.test"
        PlexStubProtocol.register(host: host, path: "/library/sections/2/all", stub: .init(status: 200, body: """
        {"MediaContainer": {"size": 1, "totalSize": 1, "Metadata": [
          {"ratingKey": "5", "type": "episode", "title": "It's fate!",
           "grandparentRatingKey": "3", "grandparentTitle": "Love Is Blind: Germany",
           "parentIndex": 2, "index": 1, "duration": 3648704,
           "Media": [{"container": "mkv", "Part": [{"key": "/library/parts/5/1789378778/file.mkv"}]}]}
        ]}}
        """))

        let page = try await makeClient().items(server: server(host), token: "tok", sectionKey: "2", type: PlexClient.episodeType)
        let episode = try #require(page.items.first)
        #expect(episode.grandparentRatingKey == "3")
        #expect(episode.parentIndex == 2)
        #expect(episode.index == 1)
        #expect(episode.partKey == "/library/parts/5/1789378778/file.mkv")
    }

    // MARK: - Sign-in

    @Test func `sign-in returns the account token`() async throws {
        let host = "plexaccount.test"
        PlexStubProtocol.register(host: host, path: "/api/v2/users/signin", stub: .init(status: 201, body: """
        {"authToken": "acct-token", "id": 1}
        """))

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlexStubProtocol.self]
        let client = try PlexClient(urlSession: URLSession(configuration: config), accountBaseURL: #require(URL(string: "http://\(host)")))
        #expect(try await client.signIn(username: "bilipp", password: "test") == "acct-token")
    }

    @Test func `a rejected sign-in surfaces as unauthorized`() async throws {
        let host = "plexbadaccount.test"
        PlexStubProtocol.register(host: host, path: "/api/v2/users/signin", stub: .init(status: 401, body: ""))

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlexStubProtocol.self]
        let client = try PlexClient(urlSession: URLSession(configuration: config), accountBaseURL: #require(URL(string: "http://\(host)")))
        let result = await failure { _ = try await client.signIn(username: "bilipp", password: "wrong") }
        #expect(result == PlexError.unauthorized.logDescription)
    }

    // MARK: - URL builders

    /// The stored stream URL must never carry the token: it reaches deep
    /// links, Cast payloads and window-restoration state.
    @Test func `the stream URL stays token-free while the image URL carries one`() throws {
        let base = try #require(URL(string: "http://plex.test:32400"))
        let stream = try #require(PlexClient.streamURL(server: base, partKey: "/library/parts/1/17/file.mp4"))
        #expect(stream.absoluteString == "http://plex.test:32400/library/parts/1/17/file.mp4")
        #expect(!stream.absoluteString.contains("X-Plex-Token"))

        let image = try #require(PlexClient.imageURL(server: base, path: "/library/metadata/1/thumb/17", token: "tok"))
        #expect(image.absoluteString == "http://plex.test:32400/library/metadata/1/thumb/17?X-Plex-Token=tok")
    }

    @Test func `a token-free server yields a token-free image URL`() throws {
        let base = try #require(URL(string: "http://plex.test:32400"))
        let image = try #require(PlexClient.imageURL(server: base, path: "/library/metadata/1/thumb/17", token: nil))
        #expect(image.absoluteString == "http://plex.test:32400/library/metadata/1/thumb/17")
    }

    @Test func `no token means no playback headers`() {
        #expect(PlexClient.playbackHeaders(token: nil) == nil)
        #expect(PlexClient.playbackHeaders(token: "") == nil)
        #expect(PlexClient.playbackHeaders(token: "tok") == ["X-Plex-Token": "tok"])
    }

    @Test func `a trailing slash is stripped so path building never doubles one`() throws {
        let normalized = try PlexClient.normalizedServerURL(#require(URL(string: "http://plex.test:32400/")))
        #expect(normalized.absoluteString == "http://plex.test:32400")
    }

    // MARK: - Playback auth

    @Test func `the header-less engine folds the token into a transient query item`() throws {
        let url = try #require(URL(string: "http://plex.test:32400/library/parts/1/17/file.mp4"))
        let headers = PlexClient.playbackHeaders(token: "tok")
        let authenticated = try #require(PlexPlaybackAuth.authenticatedURL(url, headers: headers))
        #expect(authenticated.absoluteString == "http://plex.test:32400/library/parts/1/17/file.mp4?X-Plex-Token=tok")
    }

    @Test func `a URL that already carries a token is left alone`() throws {
        let url = try #require(URL(string: "http://plex.test:32400/file.mp4?X-Plex-Token=existing"))
        let authenticated = try #require(PlexPlaybackAuth.authenticatedURL(url, headers: ["X-Plex-Token": "tok"]))
        #expect(authenticated.absoluteString == url.absoluteString)
    }

    @Test func `a Jellyfin header is not mistaken for a Plex one`() throws {
        let headers = JellyfinClient.playbackHeaders(token: "jf")
        #expect(PlexPlaybackAuth.token(from: headers) == nil)
        #expect(try PlexPlaybackAuth.authenticatedURL(#require(URL(string: "http://x/y")), headers: headers) == nil)
    }

    // MARK: - Catalog helpers

    @Test func `a numeric rating key becomes the stream id verbatim`() {
        #expect(ContentSyncManager.plexStreamId("25") == 25)
        // A non-numeric key still has to produce a launch-stable id.
        let hashed = ContentSyncManager.plexStreamId("abc")
        #expect(hashed == ContentSyncManager.plexStreamId("abc"))
        #expect(hashed != ContentSyncManager.plexStreamId("abd"))
    }

    @Test func `addedAt becomes the yyyy-MM-dd string the catalog stores`() {
        #expect(ContentSyncManager.plexDateString(from: 1_789_592_930) == "2026-09-16")
        #expect(ContentSyncManager.plexDateString(from: 0) == "1970-01-01")
    }
}

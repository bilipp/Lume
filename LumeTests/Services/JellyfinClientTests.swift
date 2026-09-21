import Foundation
@testable import Lume
import Testing

/// Serves one canned response per path and records the request, so the login
/// verb, the `Authorization` (not `X-Emby-Authorization`) header and the
/// token-bearing follow-ups can be asserted.
///
/// Purpose-built rather than shared: Jellyfin routes on paths and JSON bodies,
/// and each test injects its own session — never registered globally.
private final nonisolated class JellyfinStubProtocol: URLProtocol {
    struct Stub {
        var status: Int
        var body: String
    }

    struct Recorded {
        var method: String?
        var authorization: String?
        var body: String?
        var url: String?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [String: Stub] = [:]
    private nonisolated(unsafe) static var recorded: [String: Recorded] = [:]

    /// Keyed by host + path: suites run in parallel and every test uses its
    /// own host (see the `server(_:)` helper), so no two tests share a key.
    static func register(host: String, path: String, stub: Stub) {
        lock.withLock {
            stubs[host + path] = stub
            recorded[host + path] = nil
        }
    }

    static func recorded(host: String, path: String) -> Recorded? {
        lock.withLock { recorded[host + path] }
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
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let path = url.path

        var body: String?
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 {
                    break
                }
                data.append(contentsOf: buffer[0 ..< read])
            }
            stream.close()
            body = String(data: data, encoding: .utf8)
        } else if let direct = request.httpBody {
            body = String(data: direct, encoding: .utf8)
        }

        let key = (url.host ?? "") + path
        let stub: Stub? = Self.lock.withLock {
            Self.recorded[key] = Recorded(
                method: request.httpMethod,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                body: body,
                url: url.absoluteString
            )
            return Self.stubs[key]
        }
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct JellyfinClientTests {
    private func makeClient() -> JellyfinClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JellyfinStubProtocol.self]
        return JellyfinClient(urlSession: URLSession(configuration: config))
    }

    /// One host per test: suites run in parallel and stubs are keyed by path,
    /// so two tests sharing a host would overwrite each other's stub and
    /// recorded request (the WebDAV suite uses per-test hosts for the same
    /// reason).
    private func server(_ host: String) -> URL {
        URL(string: "http://\(host):8096")!
    }

    /// `JellyfinError` cannot be `Equatable` (it carries an `Error`), so
    /// failures are compared through `logDescription`, like the WebDAV suite.
    private func failure(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch let error as JellyfinError {
            return error.logDescription
        } catch {
            return "unexpected: \(error)"
        }
    }

    // MARK: - Authentication

    @Test func `login posts credentials and decodes the session`() async throws {
        let host = "jflogin.test"
        JellyfinStubProtocol.register(host: host, path: "/Users/AuthenticateByName", stub: .init(status: 200, body: """
        {"AccessToken": "tok123", "User": {"Id": "user1"}}
        """))

        let server = server(host)
        let session = try await makeClient().authenticate(server: server, username: "bilipp", password: "test")

        #expect(session.accessToken == "tok123")
        #expect(session.userId == "user1")

        let recorded = try #require(JellyfinStubProtocol.recorded(host: host, path: "/Users/AuthenticateByName"))
        #expect(recorded.method == "POST")
        // Jellyfin 10.12+ with legacy auth disabled only accepts this form —
        // the `X-Emby-Authorization` variant answers 400 there.
        #expect(recorded.authorization?.hasPrefix("MediaBrowser Client=\"Lume\"") == true)
        #expect(recorded.body?.contains("\"Username\":\"bilipp\"") == true)
        #expect(recorded.body?.contains("\"Pw\":\"test\"") == true)
    }

    @Test func `a 401 surfaces as unauthorized`() async {
        let host = "jf401.test"
        JellyfinStubProtocol.register(host: host, path: "/Users/AuthenticateByName", stub: .init(status: 401, body: ""))

        let result = await failure {
            _ = try await makeClient().authenticate(server: server(host), username: "bilipp", password: "wrong")
        }
        #expect(result == JellyfinError.unauthorized.logDescription)
    }

    // MARK: - Probe

    @Test func `probe accepts a Jellyfin server`() async throws {
        let host = "jfprobeok.test"
        JellyfinStubProtocol.register(host: host, path: "/System/Info/Public", stub: .init(status: 200, body: """
        {"ProductName": "Jellyfin Server", "Version": "10.11.0"}
        """))

        #expect(try await makeClient().probe(server: server(host)) == .jellyfin)
    }

    /// Emby sends no `ProductName` at all — the server identity it does send
    /// is what tells it apart from an unrelated JSON endpoint.
    @Test func `probe recognizes Emby by its server identity`() async throws {
        let host = "embyprobeok.test"
        JellyfinStubProtocol.register(host: host, path: "/System/Info/Public", stub: .init(status: 200, body: """
        {"ServerName": "3ebc5c5eeb03", "Version": "4.9.5.0", "Id": "2f56ec98046d457392faaed24a274c2e"}
        """))

        #expect(try await makeClient().probe(server: server(host)) == .emby)
    }

    @Test func `probe rejects a host that is neither`() async {
        let host = "jfprobebad.test"
        JellyfinStubProtocol.register(host: host, path: "/System/Info/Public", stub: .init(status: 200, body: """
        {"ProductName": "Something Else"}
        """))

        let result = await failure { _ = try await makeClient().probe(server: server(host)) }
        #expect(result == JellyfinError.notAMediaServer.logDescription)
    }

    /// A 200 with unrelated JSON must not read as Emby just because
    /// `ProductName` is missing.
    @Test func `probe rejects an unrelated JSON endpoint`() async {
        let host = "jfprobejson.test"
        JellyfinStubProtocol.register(host: host, path: "/System/Info/Public", stub: .init(status: 200, body: """
        {"status": "ok"}
        """))

        let result = await failure { _ = try await makeClient().probe(server: server(host)) }
        #expect(result == JellyfinError.notAMediaServer.logDescription)
    }

    // MARK: - Libraries & items

    @Test func `views decode libraries with their collection types`() async throws {
        let host = "jfviews.test"
        JellyfinStubProtocol.register(host: host, path: "/Users/user1/Views", stub: .init(status: 200, body: """
        {"Items": [
          {"Id": "lib1", "Name": "Movies", "CollectionType": "movies"},
          {"Id": "lib2", "Name": "TV Shows", "CollectionType": "tvshows"},
          {"Id": "lib3", "Name": "Music", "CollectionType": "music"}
        ], "TotalRecordCount": 3}
        """))

        let views = try await makeClient().views(server: server(host), session: JellyfinSession(accessToken: "tok", userId: "user1"))

        #expect(views.count == 3)
        #expect(views.first?.collectionType == "movies")
    }

    @Test func `item queries carry the session token`() async throws {
        let host = "jfitems.test"
        JellyfinStubProtocol.register(host: host, path: "/Users/user1/Items", stub: .init(status: 200, body: """
        {"Items": [
          {"Id": "m1", "Name": "Arrival", "Type": "Movie", "CommunityRating": 7.5,
           "ImageTags": {"Primary": "tag1"}, "ProviderIds": {"Tmdb": "329865"}}
        ], "TotalRecordCount": 1}
        """))

        let response = try await makeClient().items(
            server: server(host), session: JellyfinSession(accessToken: "tok", userId: "user1"),
            parentId: "lib1", types: ["Movie"]
        )

        #expect(response.totalRecordCount == 1)
        let item = try #require(response.items.first)
        #expect(item.itemType == "Movie")
        #expect(item.durationSecs == nil)
        #expect(item.primaryImageTag == "tag1")

        let recorded = try #require(JellyfinStubProtocol.recorded(host: host, path: "/Users/user1/Items"))
        #expect(recorded.authorization?.contains("Token=\"tok\"") == true)
        #expect(recorded.url?.contains("IncludeItemTypes=Movie") == true)
        #expect(recorded.url?.contains("ParentId=lib1") == true)
    }

    @Test func `runtime ticks convert to seconds`() throws {
        let json = """
        {"Id": "m1", "Name": "Arrival", "Type": "Movie", "RunTimeTicks": 82945066670}
        """
        let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
        // 82945066670 ticks / 10_000_000 ≈ 8294 s
        #expect(item.durationSecs == 8294)
    }

    // MARK: - URL builders

    @Test func `stream URLs are token-free`() throws {
        let url = try #require(JellyfinClient.streamURL(server: server("jellyfin.test"), itemId: "abc"))
        #expect(url.absoluteString == "http://jellyfin.test:8096/Videos/abc/stream?Static=true")
    }

    @Test func `image URLs embed the tag and the token`() throws {
        let url = try #require(JellyfinClient.imageURL(server: server("jellyfin.test"), itemId: "abc", tag: "tag1", token: "tok"))
        #expect(url.absoluteString.contains("/Items/abc/Images/Primary"))
        #expect(url.absoluteString.contains("tag=tag1"))
        #expect(url.absoluteString.contains("api_key=tok"))
    }

    // MARK: - Playback auth

    @Test func `playback headers carry the session token`() throws {
        // The full client form, not a bare token: the server logs the session
        // against the client/device. The device id is install-stable, so only
        // the shape and the token are asserted.
        let headers = try #require(JellyfinClient.playbackHeaders(token: "tok"))
        let value = try #require(headers["Authorization"])
        #expect(value.hasPrefix("MediaBrowser Client=\"Lume\""))
        #expect(value.contains("Token=\"tok\""))
    }

    @Test func `no session means no headers`() {
        #expect(JellyfinClient.playbackHeaders(token: nil) == nil)
        #expect(JellyfinClient.playbackHeaders(token: "") == nil)
    }

    @Test func `a jellyfin movie plays through the token-free stream URL with a header`() throws {
        let playlist = Playlist(
            name: "JF", mediaServerURL: "http://jellyfin.test:8096", flavor: .jellyfin,
            username: "bilipp", password: "test", accessToken: "tok", userId: "user1"
        )
        let movie = Movie(id: "p-jellyfin-abc", streamId: 1, name: "Arrival")
        movie.directURL = "http://jellyfin.test:8096/Videos/abc/stream?Static=true"

        let media = try #require(PlayableMedia.from(movie: movie, playlist: playlist))
        #expect(media.url.absoluteString == "http://jellyfin.test:8096/Videos/abc/stream?Static=true")
        #expect(media.httpHeaders?["Authorization"]?.contains("Token=\"tok\"") == true)
    }

    @Test func `a jellyfin episode takes the direct-source path`() throws {
        let playlist = Playlist(
            name: "JF", mediaServerURL: "http://jellyfin.test:8096", flavor: .jellyfin,
            username: "bilipp", password: "test", accessToken: "tok", userId: "user1"
        )
        let episode = Episode(
            id: "e-1", episodeId: "ep1", title: "Pilot", containerExtension: "mkv",
            seasonNum: 1, episodeNum: 1,
            directSource: "http://jellyfin.test:8096/Videos/ep1/stream?Static=true"
        )

        let media = try #require(PlayableMedia.from(episode: episode, playlist: playlist))
        #expect(media.url.absoluteString == "http://jellyfin.test:8096/Videos/ep1/stream?Static=true")
        #expect(media.httpHeaders?["Authorization"]?.contains("Token=\"tok\"") == true)
    }

    @Test func `the header-less engine folds the token into a transient api_key`() throws {
        let url = try #require(URL(string: "http://jellyfin.test:8096/Videos/abc/stream?Static=true"))
        let headers = ["Authorization": "MediaBrowser Token=\"tok\""]
        let authed = try #require(JellyfinPlaybackAuth.authenticatedURL(url, headers: headers))
        #expect(authed.absoluteString.contains("api_key=tok"))
        #expect(authed.absoluteString.contains("Static=true"))
    }

    @Test func `a basic header is not mistaken for a jellyfin token`() throws {
        let url = try #require(URL(string: "http://example.com/f.mkv"))
        let headers = ["Authorization": "Basic YmlsaXBwOnRlc3Q="]
        #expect(JellyfinPlaybackAuth.token(from: headers) == nil)
        #expect(JellyfinPlaybackAuth.authenticatedURL(url, headers: headers) == nil)
        #expect(JellyfinPlaybackAuth.authenticatedURL(url, headers: nil) == nil)
    }

    // MARK: - Sync steps & identity

    @Test func `jellyfin sync walks login then movies then series`() {
        #expect(SyncStep.steps(for: .jellyfin) == [.authenticating, .movies, .series])
    }

    @Test func `the jellyfin id hash is stable and positive`() {
        let first = ContentSyncManager.mediaServerHash("814993f8d3f97a7b8a40e2ca4dbd3187")
        #expect(first == ContentSyncManager.mediaServerHash("814993f8d3f97a7b8a40e2ca4dbd3187"))
        #expect(first > 0)
        #expect(ContentSyncManager.mediaServerHash("other-id") != first)
    }
}

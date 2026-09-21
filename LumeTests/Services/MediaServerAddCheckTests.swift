//
//  MediaServerAddCheckTests.swift
//  LumeTests
//
//  The media-server entry point: URL auto-detection (Jellyfin, Emby, Plex and
//  WebDAV) and the failure copy. Detection probes are stubbed per host; which failure gets
//  which copy is asserted through `MediaServerAddCheck.message`, which
//  delegates to the per-kind checks for everything they already distinguish.
//

import Foundation
@testable import Lume
import Testing

/// Serves canned replies per `METHOD path`, optionally demanding HTTP Basic
/// auth for PROPFIND (to model a share that requires credentials).
///
/// Keyed by a per-test host so parallel suites can never collide, and injected
/// via the checks' `urlSession` seam — never registered globally.
private final nonisolated class MediaServerStubProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
        /// When true, a request carrying neither an `Authorization` header
        /// nor an `X-Plex-Token` gets a 401 instead of the reply.
        var requiresAuth: Bool = false
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var replies: [String: [String: Reply]] = [:]

    static func install(host: String, replies: [String: Reply]) {
        lock.withLock { Self.replies[host] = replies }
    }

    static func remove(host: String) {
        lock.withLock { replies[host] = nil }
    }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".mediaserver.test") == true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        // `path(percentEncoded:)`, not `.path`: the latter strips a trailing
        // slash on this toolchain while the request URL keeps it, so a `/Movies/`
        // route would never match (the WebDAV suite matches this way too).
        let key = "\(request.httpMethod ?? "GET") \(url.path(percentEncoded: true))"
        let reply = Self.lock.withLock { Self.replies[host]?[key] }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        // A negative status emulates a dead host: the request fails in
        // transport instead of answering.
        if reply.status < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let credentialed = request.value(forHTTPHeaderField: "Authorization") != nil
            || request.value(forHTTPHeaderField: "X-Plex-Token") != nil
        if reply.requiresAuth, !credentialed {
            guard let denied = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: denied, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct MediaServerAddCheckTests {
    private func host(_ name: String) -> String {
        "\(name)-\(UUID().uuidString.prefix(8).lowercased()).mediaserver.test"
    }

    /// A session answering only from `MediaServerStubProtocol`, so the checks
    /// under test never touch the network.
    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaServerStubProtocol.self]
        return URLSession(configuration: config)
    }

    private func input(url: String, username: String = "bilipp", password: String = "test") -> MediaServerAddCheck.Input {
        .init(url: url, username: username, password: password)
    }

    private func webdavCollection(_ href: String, children: [String]) -> String {
        let rows = ([href] + children).map { child in
            let props = child == href
                ? "<lp1:resourcetype><D:collection/></lp1:resourcetype>"
                : "<lp1:resourcetype/><lp1:getcontentlength>42</lp1:getcontentlength>"
            return """
            <D:response xmlns:lp1="DAV:"><D:href>\(child)</D:href><D:propstat><D:prop>\(props)</D:prop>\
            <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">\(rows)</D:multistatus>
        """
    }

    // MARK: - Detection

    @Test func `a Jellyfin server is detected and logged into`() async throws {
        let testHost = host("jellyfin")
        defer { MediaServerStubProtocol.remove(host: testHost) }
        MediaServerStubProtocol.install(host: testHost, replies: [
            "GET /System/Info/Public": .init(status: 200, body: """
            {"ProductName": "Jellyfin Server", "Version": "10.11.0"}
            """),
            "POST /Users/AuthenticateByName": .init(status: 200, body: """
            {"AccessToken": "tok", "User": {"Id": "user1"}}
            """)
        ])

        let verified = try await MediaServerAddCheck.verify(input(url: "http://\(testHost):8096/"), urlSession: stubSession())
        guard case let .mediaServer(serverURL, flavor, session) = verified else {
            Issue.record("Expected .mediaServer, got \(verified)")
            return
        }
        #expect(flavor == .jellyfin)
        // Stored without the trailing slash, so path building never doubles one.
        #expect(serverURL == "http://\(testHost):8096")
        #expect(session.accessToken == "tok")
        #expect(session.userId == "user1")
    }

    /// Emby answers the same public endpoint without a `ProductName`, so the
    /// same probe has to route it to the same login flow under its own
    /// flavour.
    @Test func `an Emby server is detected and logged into`() async throws {
        let testHost = host("emby")
        defer { MediaServerStubProtocol.remove(host: testHost) }
        MediaServerStubProtocol.install(host: testHost, replies: [
            "GET /System/Info/Public": .init(status: 200, body: """
            {"ServerName": "media", "Version": "4.9.5.0", "Id": "2f56ec98046d"}
            """),
            "POST /Users/AuthenticateByName": .init(status: 200, body: """
            {"AccessToken": "tok", "User": {"Id": "user1"}}
            """)
        ])

        let verified = try await MediaServerAddCheck.verify(input(url: "http://\(testHost):8096/"), urlSession: stubSession())
        guard case let .mediaServer(serverURL, flavor, session) = verified else {
            Issue.record("Expected .mediaServer, got \(verified)")
            return
        }
        #expect(flavor == .emby)
        #expect(serverURL == "http://\(testHost):8096")
        #expect(session.accessToken == "tok")
    }

    @Test func `a Plex server is detected and signed into`() async throws {
        let testHost = host("plex")
        defer { MediaServerStubProtocol.remove(host: testHost) }
        MediaServerStubProtocol.install(host: testHost, replies: [
            // Not a Jellyfin/Emby server, so that probe has to fall through.
            "GET /System/Info/Public": .init(status: 404, body: ""),
            "GET /identity": .init(status: 200, body: """
            {"MediaContainer": {"size": 0, "machineIdentifier": "05392f7b"}}
            """),
            "GET /library/sections": .init(status: 200, body: """
            {"MediaContainer": {"size": 1, "Directory": [{"key": "1", "title": "Movies", "type": "movie"}]}}
            """)
        ])

        let verified = try await MediaServerAddCheck.verify(
            input(url: "http://\(testHost):32400/", username: "", password: ""),
            urlSession: stubSession()
        )
        guard case let .plex(serverURL, token) = verified else {
            Issue.record("Expected .plex, got \(verified)")
            return
        }
        #expect(serverURL == "http://\(testHost):32400")
        // A server that answers unauthenticated stores no credential at all.
        #expect(token == nil)
    }

    /// The password field doubles as an `X-Plex-Token` when no username is
    /// entered, so a user who has a token never needs a plex.tv round trip.
    /// It is used only once the unauthenticated attempt has been refused —
    /// see `PlexAddCheck.resolveToken` for why that order matters.
    @Test func `a password-only Plex entry is treated as a token`() async throws {
        let testHost = host("plextoken")
        defer { MediaServerStubProtocol.remove(host: testHost) }
        MediaServerStubProtocol.install(host: testHost, replies: [
            "GET /System/Info/Public": .init(status: 404, body: ""),
            "GET /identity": .init(status: 200, body: """
            {"MediaContainer": {"machineIdentifier": "05392f7b"}}
            """),
            "GET /library/sections": .init(status: 200, body: """
            {"MediaContainer": {"Directory": [{"key": "1", "title": "Movies", "type": "movie"}]}}
            """, requiresAuth: true)
        ])

        let verified = try await MediaServerAddCheck.verify(
            input(url: "http://\(testHost):32400", username: "", password: "plex-token-123"),
            urlSession: stubSession()
        )
        guard case let .plex(_, token) = verified else {
            Issue.record("Expected .plex, got \(verified)")
            return
        }
        #expect(token == "plex-token-123")
    }

    /// A server with unauthenticated local access answers metadata for any
    /// token value, including a wrong one, but 503s the media itself. Storing
    /// a token it never needed would browse fine and play nothing, so a
    /// pasted token must lose to the unauthenticated attempt.
    @Test func `a pasted token is dropped when the server needs none`() async throws {
        let testHost = host("plexopen")
        defer { MediaServerStubProtocol.remove(host: testHost) }
        MediaServerStubProtocol.install(host: testHost, replies: [
            "GET /System/Info/Public": .init(status: 404, body: ""),
            "GET /identity": .init(status: 200, body: """
            {"MediaContainer": {"machineIdentifier": "05392f7b"}}
            """),
            // Answers with or without a token, like a real open server.
            "GET /library/sections": .init(status: 200, body: """
            {"MediaContainer": {"Directory": [{"key": "1", "title": "Movies", "type": "movie"}]}}
            """)
        ])

        let verified = try await MediaServerAddCheck.verify(
            input(url: "http://\(testHost):32400", username: "", password: "a-token-it-does-not-need"),
            urlSession: stubSession()
        )
        guard case let .plex(_, token) = verified else {
            Issue.record("Expected .plex, got \(verified)")
            return
        }
        #expect(token == nil)
    }

    /// A Plex server that needs a token must not be stored token-free: the
    /// playlist would sync to nothing on every run.
    @Test func `a Plex server that refuses an anonymous listing reports unauthorized`() async throws {
        let testHost = host("plexlocked")
        defer { MediaServerStubProtocol.remove(host: testHost) }
        MediaServerStubProtocol.install(host: testHost, replies: [
            "GET /System/Info/Public": .init(status: 404, body: ""),
            "GET /identity": .init(status: 200, body: """
            {"MediaContainer": {"machineIdentifier": "05392f7b"}}
            """),
            "GET /library/sections": .init(status: 401, body: "")
        ])

        let error = await #expect(throws: PlexError.self) {
            _ = try await MediaServerAddCheck.verify(
                input(url: "http://\(testHost):32400", username: "", password: ""),
                urlSession: stubSession()
            )
        }
        #expect(error?.logDescription == PlexError.unauthorized.logDescription)
    }

    @Test func `a WebDAV share is detected and listed`() async throws {
        let testHost = host("webdav")
        defer { MediaServerStubProtocol.remove(host: testHost) }
        let body = webdavCollection("/Movies/", children: ["/Movies/Arrival.2016.mkv"])
        MediaServerStubProtocol.install(host: testHost, replies: [
            "GET /Movies/System/Info/Public": .init(status: 404, body: ""),
            "PROPFIND /Movies/": .init(status: 207, body: body)
        ])

        let verified = try await MediaServerAddCheck.verify(input(url: "http://\(testHost)/Movies/"), urlSession: stubSession())
        guard case let .webdav(url) = verified else {
            Issue.record("Expected .webdav, got \(verified)")
            return
        }
        #expect(url == "http://\(testHost)/Movies/")
    }

    @Test func `a 401 to the anonymous probe still means WebDAV`() async throws {
        let testHost = host("locked")
        defer { MediaServerStubProtocol.remove(host: testHost) }
        let body = webdavCollection("/Share/", children: ["/Share/Arrival.2016.mkv"])
        MediaServerStubProtocol.install(host: testHost, replies: [
            "GET /Share/System/Info/Public": .init(status: 404, body: ""),
            // Anonymous probe: refused. Credentialed probe + listing: served.
            "PROPFIND /Share/": .init(status: 207, body: body, requiresAuth: true)
        ])

        let verified = try await MediaServerAddCheck.verify(input(url: "http://\(testHost)/Share/"), urlSession: stubSession())
        guard case .webdav = verified else {
            Issue.record("Expected .webdav, got \(verified)")
            return
        }
    }

    @Test func `a plain web server is neither and reports unsupported`() async throws {
        let testHost = host("plain")
        defer { MediaServerStubProtocol.remove(host: testHost) }
        MediaServerStubProtocol.install(host: testHost, replies: [
            "GET /System/Info/Public": .init(status: 404, body: "<html>Index</html>"),
            "GET /identity": .init(status: 404, body: "<html>Index</html>"),
            "PROPFIND /": .init(status: 404, body: "")
        ])

        let error = await #expect(throws: MediaServerError.self) {
            _ = try await MediaServerAddCheck.verify(input(url: "http://\(testHost)/"), urlSession: stubSession())
        }
        #expect(error == .unsupported)
    }

    @Test func `a dead host reports the network error, not unsupported`() async throws {
        let testHost = host("dead")
        defer { MediaServerStubProtocol.remove(host: testHost) }
        MediaServerStubProtocol.install(host: testHost, replies: [
            "GET /System/Info/Public": .init(status: -1, body: ""),
            "GET /identity": .init(status: -1, body: ""),
            "PROPFIND /": .init(status: -1, body: "")
        ])

        // Every probe dies in transport, so detection passes the first
        // network error through instead of relabeling it "unsupported".
        let error = await #expect(throws: JellyfinError.self) {
            _ = try await MediaServerAddCheck.verify(input(url: "http://\(testHost)/"), urlSession: stubSession())
        }
        guard case .networkError = try #require(error) else {
            Issue.record("Expected .networkError, got \(String(describing: error))")
            return
        }
    }

    @Test func `a Jellyfin server without a username asks for credentials`() async throws {
        let testHost = host("nouser")
        defer { MediaServerStubProtocol.remove(host: testHost) }
        MediaServerStubProtocol.install(host: testHost, replies: [
            "GET /System/Info/Public": .init(status: 200, body: """
            {"ProductName": "Jellyfin Server", "Version": "10.11.0"}
            """)
        ])

        let error = await #expect(throws: MediaServerError.self) {
            _ = try await MediaServerAddCheck.verify(input(url: "http://\(testHost):8096", username: "", password: ""), urlSession: stubSession())
        }
        #expect(error == .missingCredentials)
    }

    // MARK: - Copy

    @Test func `unsupported names every server kind`() {
        let copy = MediaServerAddCheck.message(for: MediaServerError.unsupported, input: input(url: "http://example.com/"), timedOut: false)
        for kind in ["Jellyfin", "Emby", "Plex", "WebDAV"] {
            #expect(copy.localizedCaseInsensitiveContains(kind), "copy should name \(kind): \(copy)")
        }
    }

    /// A 401 means something different for each Plex token source, so each
    /// one has to tell the user what to do next.
    @Test func `the Plex failure copy matches the credential the user entered`() {
        let account = PlexAddCheck.message(
            for: PlexError.unauthorized,
            input: .init(url: "http://nas:32400", username: "bilipp", password: "test"),
            timedOut: false
        )
        #expect(account.localizedCaseInsensitiveContains("two-factor"))

        let token = PlexAddCheck.message(
            for: PlexError.unauthorized,
            input: .init(url: "http://nas:32400", username: "", password: "tok"),
            timedOut: false
        )
        #expect(token.localizedCaseInsensitiveContains("X-Plex-Token"))

        let anonymous = PlexAddCheck.message(
            for: PlexError.unauthorized,
            input: .init(url: "http://nas:32400", username: "", password: ""),
            timedOut: false
        )
        #expect(anonymous.localizedCaseInsensitiveContains("sign-in"))
    }

    @Test func `missing credentials ask for a username and password`() {
        let copy = MediaServerAddCheck.message(for: MediaServerError.missingCredentials, input: input(url: "http://nas:8096", username: ""), timedOut: false)
        #expect(copy.localizedCaseInsensitiveContains("username"))
        #expect(copy.localizedCaseInsensitiveContains("password"))
    }

    @Test func `a wrong Jellyfin password keeps the Jellyfin copy`() {
        let copy = MediaServerAddCheck.message(for: JellyfinError.unauthorized, input: input(url: "http://nas:8096"), timedOut: false)
        #expect(copy.localizedCaseInsensitiveContains("username"))
        #expect(copy.localizedCaseInsensitiveContains("password"))
    }

    @Test func `a wrong WebDAV password keeps the anonymous-share hint`() {
        let copy = MediaServerAddCheck.message(for: WebDAVError.unauthorized, input: input(url: "http://nas/Share/"), timedOut: false)
        #expect(copy.localizedCaseInsensitiveContains("empty"))
    }

    @Test func `a timeout against a local address still blames the local network`() {
        let copy = MediaServerAddCheck.message(
            for: LoginView.ConnectionTimeoutError(),
            input: input(url: "http://192.168.1.10:8096"),
            timedOut: true
        )
        #expect(copy.localizedCaseInsensitiveContains("local network"))
    }
}

//
//  MediaServerAddCheckTests.swift
//  LumeTests
//
//  The media-server entry point: URL auto-detection (Jellyfin vs. WebDAV) and
//  the failure copy. Detection probes are stubbed per host; which failure gets
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
        /// When true, an anonymous request gets a 401 instead of the reply.
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
        if reply.requiresAuth, request.value(forHTTPHeaderField: "Authorization") == nil {
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
        guard case let .jellyfin(serverURL, session) = verified else {
            Issue.record("Expected .jellyfin, got \(verified)")
            return
        }
        // Stored without the trailing slash, so path building never doubles one.
        #expect(serverURL == "http://\(testHost):8096")
        #expect(session.accessToken == "tok")
        #expect(session.userId == "user1")
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
            "PROPFIND /": .init(status: -1, body: "")
        ])

        // Both probes die in transport, so detection passes the Jellyfin
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

    @Test func `unsupported names both server kinds`() {
        let copy = MediaServerAddCheck.message(for: MediaServerError.unsupported, input: input(url: "http://example.com/"), timedOut: false)
        #expect(copy.localizedCaseInsensitiveContains("Jellyfin"))
        #expect(copy.localizedCaseInsensitiveContains("WebDAV"))
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

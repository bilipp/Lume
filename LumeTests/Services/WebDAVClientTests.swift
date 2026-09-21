import Foundation
@testable import Lume
import Testing

/// Serves one canned response per host and records the request that asked for
/// it, so the PROPFIND verb, `Depth` and preemptive `Authorization` header can
/// be asserted.
///
/// Purpose-built rather than reusing `StubURLProtocol`: that one routes on a
/// query item, which a PROPFIND URL does not carry, and it is shared with other
/// suites. Never registered globally — each test injects its own session.
private final nonisolated class WebDAVStubProtocol: URLProtocol {
    struct Stub {
        var status: Int
        var body: String
        var contentType: String = "text/xml; charset=\"utf-8\""
    }

    struct Recorded {
        var method: String?
        var depth: String?
        var authorization: String?
        var contentType: String?
        var body: String?
        var url: String?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [String: Stub] = [:]
    private nonisolated(unsafe) static var recorded: [String: Recorded] = [:]

    static func register(host: String, stub: Stub) {
        lock.withLock {
            stubs[host] = stub
            recorded[host] = nil
        }
    }

    static func recorded(host: String) -> Recorded? {
        lock.withLock { recorded[host] }
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
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        // `URLSession` hands the protocol the body as a stream, never as
        // `httpBody`.
        var body: String?
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer[0 ..< read])
            }
            stream.close()
            body = String(data: data, encoding: .utf8)
        }

        let stub: Stub? = Self.lock.withLock {
            Self.recorded[host] = Recorded(
                method: request.httpMethod,
                depth: request.value(forHTTPHeaderField: "Depth"),
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                body: body,
                url: url.absoluteString
            )
            return Self.stubs[host]
        }
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": stub.contentType]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct WebDAVClientTests {
    private func makeClient() -> WebDAVClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WebDAVStubProtocol.self]
        return WebDAVClient(urlSession: URLSession(configuration: config))
    }

    /// `WebDAVError` cannot be `Equatable` (it carries an `Error`), so failures
    /// are compared through `logDescription`, which is a stable per-case
    /// discriminator.
    private func failure(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch let error as WebDAVError {
            return error.logDescription
        } catch {
            return "unexpected: \(error)"
        }
    }

    private func multistatus() -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        <D:response xmlns:lp1="DAV:">
        <D:href>/Movies/</D:href>
        <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        <D:response xmlns:lp1="DAV:">
        <D:href>/Movies/Arrival.2016.1080p.mkv</D:href>
        <D:propstat><D:prop>
        <lp1:resourcetype/>
        <lp1:getcontentlength>42</lp1:getcontentlength>
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        </D:multistatus>
        """
    }

    @Test func `a 207 multistatus lists the collection's children`() async throws {
        let host = "dav207.test"
        WebDAVStubProtocol.register(host: host, stub: .init(status: 207, body: multistatus()))

        let resources = try await makeClient().list(
            #require(URL(string: "http://\(host)/Movies/")),
            credentials: WebDAVCredentials(username: "bilipp", password: "test")
        )

        #expect(resources.count == 1)
        #expect(resources.first?.name == "Arrival.2016.1080p.mkv")
        #expect(resources.first?.contentLength == 42)
    }

    @Test func `the request is a PROPFIND with Depth 1 and preemptive Basic auth`() async throws {
        let host = "davrequest.test"
        WebDAVStubProtocol.register(host: host, stub: .init(status: 207, body: multistatus()))

        _ = try await makeClient().list(
            #require(URL(string: "http://\(host)/Movies/")),
            credentials: WebDAVCredentials(username: "bilipp", password: "test")
        )

        let recorded = try #require(WebDAVStubProtocol.recorded(host: host))
        #expect(recorded.method == "PROPFIND")
        #expect(recorded.depth == "1")
        #expect(recorded.contentType == "application/xml; charset=utf-8")
        #expect(recorded.authorization == "Basic YmlsaXBwOnRlc3Q=")
        #expect(recorded.body?.contains("<D:resourcetype/>") == true)
        #expect(recorded.body?.contains("<D:getcontentlength/>") == true)
    }

    @Test func `an anonymous share sends no Authorization header`() async throws {
        let host = "davanon.test"
        WebDAVStubProtocol.register(host: host, stub: .init(status: 207, body: multistatus()))

        _ = try await makeClient().list(#require(URL(string: "http://\(host)/Movies/")), credentials: nil)

        #expect(WebDAVStubProtocol.recorded(host: host)?.authorization == nil)
    }

    /// A collection URL without a trailing slash makes the server redirect to
    /// the slashed form, which drops the PROPFIND body.
    @Test func `a collection URL without a trailing slash is normalized`() async throws {
        let host = "davslash.test"
        WebDAVStubProtocol.register(host: host, stub: .init(status: 207, body: multistatus()))

        _ = try await makeClient().list(#require(URL(string: "http://\(host)/Movies")), credentials: nil)

        #expect(WebDAVStubProtocol.recorded(host: host)?.url == "http://\(host)/Movies/")
    }

    @Test func `a 401 surfaces as unauthorized`() async {
        let host = "dav401.test"
        WebDAVStubProtocol.register(host: host, stub: .init(status: 401, body: ""))

        let result = await failure {
            _ = try await makeClient().list(URL(string: "http://\(host)/Movies/")!, credentials: nil)
        }
        #expect(result == WebDAVError.unauthorized.logDescription)
    }

    @Test func `a 200 HTML page surfaces as notAWebDAVServer`() async {
        let host = "davhtml.test"
        WebDAVStubProtocol.register(host: host, stub: .init(
            status: 200,
            body: "<html><body>Index of /Movies</body></html>",
            contentType: "text/html"
        ))

        let result = await failure {
            _ = try await makeClient().list(URL(string: "http://\(host)/Movies/")!, credentials: nil)
        }
        #expect(result == WebDAVError.notAWebDAVServer.logDescription)
    }

    @Test func `a 405 surfaces as notAWebDAVServer`() async {
        let host = "dav405.test"
        WebDAVStubProtocol.register(host: host, stub: .init(status: 405, body: ""))

        let result = await failure {
            _ = try await makeClient().list(URL(string: "http://\(host)/Movies/")!, credentials: nil)
        }
        #expect(result == WebDAVError.notAWebDAVServer.logDescription)
    }

    @Test func `a 503 surfaces as a server error`() async {
        let host = "dav503.test"
        WebDAVStubProtocol.register(host: host, stub: .init(status: 503, body: ""))

        let result = await failure {
            _ = try await makeClient().list(URL(string: "http://\(host)/Movies/")!, credentials: nil)
        }
        #expect(result == WebDAVError.serverError(503).logDescription)
    }

    @Test func `probe asks only about the collection itself`() async throws {
        let host = "davprobe.test"
        WebDAVStubProtocol.register(host: host, stub: .init(status: 207, body: """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        <D:response xmlns:lp1="DAV:">
        <D:href>/Movies/</D:href>
        <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        </D:multistatus>
        """))

        try await makeClient().probe(
            #require(URL(string: "http://\(host)/Movies/")),
            credentials: WebDAVCredentials(username: "bilipp", password: "test")
        )

        let recorded = try #require(WebDAVStubProtocol.recorded(host: host))
        #expect(recorded.method == "PROPFIND")
        #expect(recorded.depth == "0")
    }

    @Test func `probe rejects a plain web server`() async {
        let host = "davprobehtml.test"
        WebDAVStubProtocol.register(host: host, stub: .init(
            status: 200,
            body: "<html><body>hello</body></html>",
            contentType: "text/html"
        ))

        let result = await failure {
            try await makeClient().probe(URL(string: "http://\(host)/Movies/")!, credentials: nil)
        }
        #expect(result == WebDAVError.notAWebDAVServer.logDescription)
    }

    /// `logDescription` is interpolated into logs as `privacy: .public`, and a
    /// `URLError` embeds the failing URL — which for WebDAV can carry userinfo.
    @Test func `a network error's log description drops the failing URL`() {
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSURLErrorFailingURLStringErrorKey: "http://bilipp:hunter2@nas.local/Movies/"
        ])

        let description = WebDAVError.networkError(underlying).logDescription

        #expect(description == "network error (NSURLErrorDomain -1001)")
        #expect(!description.contains("://"))
        #expect(!description.contains("hunter2"))
    }
}

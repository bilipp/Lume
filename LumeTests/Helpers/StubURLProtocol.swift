//
//  StubURLProtocol.swift
//  LumeTests
//
//  Shared canned-response `URLProtocol` for client tests.
//
//  It is never registered globally (`URLProtocol.registerClass`): that would
//  intercept `URLSession.shared` for every other suite and make results depend
//  on test order. Use `makeSession()` and inject the result into the client
//  under test.
//

import Foundation

final nonisolated class StubURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var body: String

        init(status: Int = 200, body: String = "") {
            self.status = status
            self.body = body
        }
    }

    /// Routes are keyed by host plus one query item, so suites whose requests
    /// all share a single host (IntroDB is one) can still run in parallel by
    /// giving each test a distinct discriminator value.
    private struct RouteKey: Hashable {
        let host: String
        let queryName: String
        let queryValue: String
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var routes: [RouteKey: Response] = [:]

    /// Registers `response` for requests to `host` carrying `query`, which is
    /// how tests sharing a host stay isolated from each other.
    static func register(host: String, query: (name: String, value: String), response: Response) {
        let key = RouteKey(host: host, queryName: query.name, queryValue: query.value)
        lock.withLock { routes[key] = response }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
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
        let items = components.queryItems ?? []

        let match = Self.lock.withLock {
            Self.routes.first { key, _ in
                key.host == host && items.contains { $0.name == key.queryName && $0.value == key.queryValue }
            }?.value
        }

        guard let match, let response = HTTPURLResponse(
            url: url, statusCode: match.status, httpVersion: nil, headerFields: nil
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(match.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

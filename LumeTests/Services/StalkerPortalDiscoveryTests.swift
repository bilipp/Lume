import Foundation
@testable import Lume
import Testing

/// Replays a provider's redirector domain: every path on `redirector.test`
/// 301s to the bare `portal.test/` (dropping path and query), which in turn
/// 301s to its `/stalker_portal/c/` page. Only `portal.test`'s
/// `/stalker_portal/server/load.php` speaks the API; everything else is HTML.
private final nonisolated class RedirectingPortalProtocol: URLProtocol {
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
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch (components.host, components.path) {
        case ("redirector.test", _):
            redirect(to: "http://portal.test/")
        case ("portal.test", "/"):
            redirect(to: "http://portal.test/stalker_portal/c/")
        case ("portal.test", "/stalker_portal/server/load.php"):
            let action = components.queryItems?.first { $0.name == "action" }?.value
            respond(action == "handshake" ? #"{"js":{"token":"TESTTOKEN"}}"# : #"{"js":{"status":"1"}}"#)
        case ("portal.test", "/stalker_portal/c/"):
            respond("<html><title>stalker_portal</title></html>")
        default:
            respond("<html>Not Found</html>", status: 404)
        }
    }

    override func stopLoading() {}

    private func respond(_ body: String, status: Int = 200) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func redirect(to target: String) {
        guard let url = request.url, let targetURL = URL(string: target),
              let response = HTTPURLResponse(
                  url: url, statusCode: 301, httpVersion: nil, headerFields: ["Location": target]
              )
        else { return }
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: targetURL), redirectResponse: response)
        client?.urlProtocolDidFinishLoading(self)
    }
}

struct StalkerPortalDiscoveryTests {
    @Test func `redirector domain resolves to the portal it redirects to`() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectingPortalProtocol.self]
        let client = StalkerClient(
            configuration: StalkerClient.Configuration(
                portalURL: "http://redirector.test/c/",
                macAddress: "00:1A:79:00:00:02"
            ),
            urlSession: URLSession(configuration: config)
        )

        let profile = try await client.authenticate()
        #expect(profile.status == "1")
    }

    @Test func `stalker_portal path hint puts its endpoint first`() {
        let endpoints = StalkerClient.candidateEndpoints(for: "http://portal.test/stalker_portal/c/")
        #expect(endpoints.first?.absoluteString == "http://portal.test/stalker_portal/server/load.php")
    }
}

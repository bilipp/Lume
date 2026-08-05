import Foundation
@testable import Lume
import Testing

/// Serves canned Stalker portal responses. Routes are keyed by request host so
/// parallel tests (each using a distinct host) don't interfere.
private final nonisolated class StalkerStubProtocol: URLProtocol {
    struct Portal {
        /// Raw response body per `p` page number of `get_ordered_list`.
        var pages: [Int: String]
        /// Pages that respond with HTTP 404 instead of a body.
        var failPages: Set<Int> = []
        var orderedListRequests = 0
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var portals: [String: Portal] = [:]

    static func register(host: String, portal: Portal) {
        lock.withLock { portals[host] = portal }
    }

    static func orderedListRequestCount(host: String) -> Int {
        lock.withLock { portals[host]?.orderedListRequests ?? 0 }
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
        let action = components.queryItems?.first { $0.name == "action" }?.value ?? ""

        func respond(_ body: String, status: Int = 200) {
            guard let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil
            ) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        switch action {
        case "handshake":
            respond(#"{"js":{"token":"TESTTOKEN"}}"#)
        case "get_profile":
            respond(#"{"js":{"status":"1"}}"#)
        case "get_ordered_list":
            let page = Int(components.queryItems?.first { $0.name == "p" }?.value ?? "") ?? 1
            let (body, fails) = Self.lock.withLock { () -> (String?, Bool) in
                Self.portals[host]?.orderedListRequests += 1
                let portal = Self.portals[host]
                return (portal?.pages[page], portal?.failPages.contains(page) ?? false)
            }
            if fails {
                respond("not found", status: 404)
            } else {
                respond(body ?? #"{"js":{"total_items":"0","max_page_items":"14","data":[]}}"#)
            }
        default:
            respond(#"{"js":{}}"#)
        }
    }

    override func stopLoading() {}
}

struct StalkerOrderedListWalkTests {
    private func makeClient(host: String) -> StalkerClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StalkerStubProtocol.self]
        return StalkerClient(
            configuration: StalkerClient.Configuration(
                portalURL: "http://\(host)/c",
                macAddress: "00:1A:79:00:00:01"
            ),
            urlSession: URLSession(configuration: config)
        )
    }

    /// One `get_ordered_list` page body carrying the given item ids.
    private func page(ids: ClosedRange<Int>, total: Int, pageSize: Int = 14) -> String {
        let items = ids
            .map { #"{"id":"\#($0)","name":"Item \#($0)","cmd":"/media/\#($0).mpg","category_id":"9"}"# }
            .joined(separator: ",")
        return #"{"js":{"total_items":"\#(total)","max_page_items":"\#(pageSize)","data":[\#(items)]}}"#
    }

    @Test func `walk fetches every page once and stops at the reported total`() async throws {
        let host = "walk-complete.test"
        StalkerStubProtocol.register(host: host, portal: .init(pages: [
            1: page(ids: 1 ... 14, total: 30),
            2: page(ids: 15 ... 28, total: 30),
            3: page(ids: 29 ... 30, total: 30)
        ]))

        var reported: [Int] = []
        let walk = try await makeClient(host: host).getAllOrderedItems(type: "vod", categoryId: "*") { count, total in
            reported.append(count)
            #expect(total == 30)
        }

        #expect(walk.items.count == 30)
        #expect(walk.complete)
        #expect(walk.items.first?.categoryId == "9")
        // Pages complete in any order (they're fetched concurrently), but the
        // running count must be monotonic and end at the total.
        #expect(reported.first == 14)
        #expect(reported.last == 30)
        #expect(reported == reported.sorted())
        // Exactly one request per page — no re-walk past the last page.
        #expect(StalkerStubProtocol.orderedListRequestCount(host: host) == 3)
    }

    @Test func `parallel pages reassemble in page order`() async throws {
        let host = "walk-ordered.test"
        StalkerStubProtocol.register(host: host, portal: .init(pages: [
            1: page(ids: 1 ... 14, total: 70),
            2: page(ids: 15 ... 28, total: 70),
            3: page(ids: 29 ... 42, total: 70),
            4: page(ids: 43 ... 56, total: 70),
            5: page(ids: 57 ... 70, total: 70)
        ]))

        let walk = try await makeClient(host: host).getAllOrderedItems(type: "vod", categoryId: "*")

        #expect(walk.complete)
        #expect(walk.items.compactMap(\.id) == (1 ... 70).map(String.init))
    }

    @Test func `walk truncated by the item cap is marked incomplete`() async throws {
        let host = "walk-capped.test"
        StalkerStubProtocol.register(host: host, portal: .init(pages: [
            1: page(ids: 1 ... 14, total: 100),
            2: page(ids: 15 ... 28, total: 100)
        ]))

        let walk = try await makeClient(host: host)
            .getAllOrderedItems(type: "vod", categoryId: "*", maxItems: 20)

        #expect(walk.items.count == 28)
        #expect(!walk.complete)
        #expect(StalkerStubProtocol.orderedListRequestCount(host: host) == 2)
    }

    @Test func `page failure mid-walk keeps earlier pages and is marked incomplete`() async throws {
        // total 20 ⇒ 2 pages: page 1 (fetched alone) succeeds, the single
        // tail page fails. A one-page tail keeps the assertion deterministic
        // despite the tail otherwise being fetched concurrently.
        let host = "walk-midfail.test"
        StalkerStubProtocol.register(host: host, portal: .init(
            pages: [1: page(ids: 1 ... 14, total: 20)],
            failPages: [2]
        ))

        let walk = try await makeClient(host: host).getAllOrderedItems(type: "vod", categoryId: "*")

        #expect(walk.items.count == 14)
        #expect(!walk.complete)
    }

    @Test func `failure on the first page throws instead of returning empty`() async throws {
        let host = "walk-firstfail.test"
        StalkerStubProtocol.register(host: host, portal: .init(pages: [:], failPages: [1]))

        await #expect(throws: StalkerError.self) {
            _ = try await makeClient(host: host).getAllOrderedItems(type: "vod", categoryId: "*")
        }
    }
}

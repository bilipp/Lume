//
//  MediaServerOpenEndedLibraryTests.swift
//  LumeTests
//
//  How the Jellyfin/Emby item walk ends: a library with a fixed length is read
//  to the end, one whose server reports a rolling total stops at a cap, and a
//  page failure inside the latter keeps what was read without pruning.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

// MARK: - Paging stub server

/// Answers login and views with canned JSON and builds every `/Items` page
/// from the request's `StartIndex`, so a library can be any length.
///
/// Keyed by a per-test host; registered only on the session handed to
/// `JellyfinClient`.
private final nonisolated class PagingJellyfinStubProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
    }

    typealias Pager = @Sendable (_ startIndex: Int) -> Reply

    private static let lock = NSLock()
    private nonisolated(unsafe) static var pagers: [String: Pager] = [:]
    private nonisolated(unsafe) static var requests: [String: [Int]] = [:]

    static func install(host: String, pager: @escaping Pager) {
        lock.withLock {
            pagers[host] = pager
            requests[host] = []
        }
    }

    static func remove(host: String) {
        lock.withLock {
            pagers[host] = nil
            requests[host] = nil
        }
    }

    /// The `StartIndex` of every item page requested so far, in order.
    static func requestedPages(host: String) -> [Int] {
        lock.withLock { requests[host] ?? [] }
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
        let reply = Self.reply(for: url, host: host)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func reply(for url: URL, host: String) -> Reply {
        switch url.path {
        case "/Users/AuthenticateByName":
            return Reply(status: 200, body: #"{"AccessToken": "sess", "User": {"Id": "user1"}}"#)
        case "/Users/user1/Views":
            return Reply(status: 200, body: """
            {"Items": [{"Id": "libMovies", "Name": "Popular", "CollectionType": "movies"}], "TotalRecordCount": 1}
            """)
        case "/Users/user1/Items":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let start = query.first { $0.name == "StartIndex" }?.value.flatMap(Int.init) ?? 0
            let pager = lock.withLock {
                requests[host, default: []].append(start)
                return pagers[host]
            }
            return pager?(start) ?? Reply(status: 404, body: "")
        default:
            return Reply(status: 404, body: "")
        }
    }
}

// MARK: - Fixtures

/// The page size the server enforces whatever `Limit` asks for.
private let pageSize = 50

private func moviePage(start: Int, count: Int, total: Int) -> PagingJellyfinStubProtocol.Reply {
    let items = (start ..< start + count).map { index in
        #"{"Id": "m\#(index)", "Name": "Movie \#(index)", "Type": "Movie"}"#
    }
    return .init(status: 200, body: """
    {"Items": [\(items.joined(separator: ","))], "TotalRecordCount": \(total)}
    """)
}

/// A ranked list with no end: every page reports what was read plus one more page.
private func rollingPage(start: Int) -> PagingJellyfinStubProtocol.Reply {
    moviePage(start: start, count: pageSize, total: start + 2 * pageSize)
}

/// A stock library of `length` items.
private func fixedPage(start: Int, length: Int) -> PagingJellyfinStubProtocol.Reply {
    moviePage(start: start, count: max(0, min(pageSize, length - start)), total: length)
}

// MARK: - Sync tests

struct MediaServerOpenEndedLibraryTests {
    private func uniqueHost() -> String {
        "paging-\(UUID().uuidString.prefix(8).lowercased()).test"
    }

    private func makeManager(container: ModelContainer) -> ContentSyncManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PagingJellyfinStubProtocol.self]
        let client = JellyfinClient(urlSession: URLSession(configuration: config))
        return ContentSyncManager(modelContainer: container, jellyfinClient: client)
    }

    private func makePlaylist(container: ModelContainer, host: String) throws -> Playlist {
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test Jellyfin", serverURL: "http://\(host):8096", username: "bilipp", password: "test")
        playlist.sourceType = MediaServerFlavor.jellyfin.sourceType
        context.insert(playlist)
        try context.save()
        return playlist
    }

    @Test func `a library with a rolling total stops at the cap`() async throws {
        let host = uniqueHost()
        defer { PagingJellyfinStubProtocol.remove(host: host) }
        PagingJellyfinStubProtocol.install(host: host) { rollingPage(start: $0) }

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        try await makeManager(container: container).syncPlaylist(playlist)

        let limit = ContentSyncManager.openEndedLibraryItemLimit
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Movie>()) == limit)
        #expect(PagingJellyfinStubProtocol.requestedPages(host: host).count == limit / pageSize)
    }

    @Test func `a fixed-length library is read to the end past the cap`() async throws {
        let host = uniqueHost()
        defer { PagingJellyfinStubProtocol.remove(host: host) }
        let length = ContentSyncManager.openEndedLibraryItemLimit + 3 * pageSize + 7
        PagingJellyfinStubProtocol.install(host: host) { fixedPage(start: $0, length: length) }

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        try await makeManager(container: container).syncPlaylist(playlist)

        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Movie>()) == length)
    }

    @Test func `a failed page in a rolling library keeps what was read and prunes nothing`() async throws {
        let host = uniqueHost()
        defer { PagingJellyfinStubProtocol.remove(host: host) }
        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        let manager = makeManager(container: container)

        // First sync: a title the second, interrupted walk never reaches.
        PagingJellyfinStubProtocol.install(host: host) { start in
            start == 0 ? moviePage(start: 400, count: 1, total: 1) : fixedPage(start: start, length: 1)
        }
        try await manager.syncPlaylist(playlist)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Movie>()) == 1)

        // Second sync: rolling pages until the server times out on the fourth.
        PagingJellyfinStubProtocol.install(host: host) { start in
            start >= 3 * pageSize ? .init(status: 504, body: "") : rollingPage(start: start)
        }
        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)
        let ids = try Set(context.fetch(FetchDescriptor<Movie>()).map(\.id))
        #expect(ids.count == 3 * pageSize + 1)
        #expect(ids.contains { $0.hasSuffix("-jellyfin-m400") })
        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.syncStatus == .idle)
    }

    @Test func `a failed page in a fixed-length library still fails the sync`() async throws {
        let host = uniqueHost()
        defer { PagingJellyfinStubProtocol.remove(host: host) }
        PagingJellyfinStubProtocol.install(host: host) { start in
            start >= 2 * pageSize ? .init(status: 504, body: "") : fixedPage(start: start, length: 4 * pageSize)
        }

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        await #expect(throws: JellyfinError.self) {
            try await makeManager(container: container).syncPlaylist(playlist)
        }
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.syncStatus == .error)
    }
}

// MARK: - Tracker

struct JellyfinTotalTrackerTests {
    private func page(count: Int, total: Int) throws -> JellyfinItemsResponse {
        let body = moviePage(start: 0, count: count, total: total).body
        return try JSONDecoder().decode(JellyfinItemsResponse.self, from: Data(body.utf8))
    }

    @Test func `a total that moves with every page is open-ended`() throws {
        var tracker = JellyfinTotalTracker()
        try tracker.record(page(count: 50, total: 100))
        #expect(!tracker.isOpenEnded)
        try tracker.record(page(count: 50, total: 150))
        #expect(tracker.isOpenEnded)
        try tracker.record(page(count: 50, total: 200))
        #expect(tracker.isOpenEnded)
        #expect(tracker.total == 200)
    }

    @Test func `a steady total is fixed`() throws {
        var tracker = JellyfinTotalTracker()
        for _ in 0 ..< 3 {
            try tracker.record(page(count: 50, total: 600))
        }
        #expect(!tracker.isOpenEnded)
        #expect(tracker.total == 600)
    }

    @Test func `a library that grows out of step with the pages stays fixed`() throws {
        var tracker = JellyfinTotalTracker()
        try tracker.record(page(count: 50, total: 600))
        try tracker.record(page(count: 50, total: 612))
        #expect(!tracker.isOpenEnded)
    }

    @Test func `one page out of step ends the open-ended reading`() throws {
        var tracker = JellyfinTotalTracker()
        try tracker.record(page(count: 50, total: 100))
        try tracker.record(page(count: 50, total: 150))
        try tracker.record(page(count: 50, total: 150))
        #expect(!tracker.isOpenEnded)
        // Once lost, a later in-step page doesn't bring it back.
        try tracker.record(page(count: 50, total: 200))
        #expect(!tracker.isOpenEnded)
    }
}

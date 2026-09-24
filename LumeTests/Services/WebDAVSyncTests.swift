//
//  WebDAVSyncTests.swift
//  LumeTests
//
//  End-to-end tests for the WebDAV sync pipeline: a stubbed PROPFIND tree is
//  walked through the real ContentSyncManager into an in-memory store.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

// MARK: - Stub server

/// Serves canned `207 Multi-Status` bodies per path and counts the PROPFINDs
/// each walk issues.
///
/// Distinct from `WebDAVClientTests`' own stub, which serves a single canned
/// response where a walk needs a routing table, and from the shared
/// `StubURLProtocol`, which routes on a query item a PROPFIND URL does not
/// carry. Registered only on the session handed to `WebDAVClient`, never
/// through `URLProtocol.registerClass`, and keyed by a per-test host so two
/// suites can never collide.
private final nonisolated class WebDAVTreeStubProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var replies: [String: [String: Reply]] = [:]
    private nonisolated(unsafe) static var requestCounts: [String: Int] = [:]

    static func install(host: String, replies: [String: Reply]) {
        lock.withLock {
            Self.replies[host] = replies
            requestCounts[host] = 0
        }
    }

    static func remove(host: String) {
        lock.withLock {
            replies[host] = nil
            requestCounts[host] = nil
        }
    }

    static func requestCount(host: String) -> Int {
        lock.withLock { requestCounts[host] ?? 0 }
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
        guard let url = request.url, let host = url.host() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let path = url.path(percentEncoded: true)
        let reply = Self.lock.withLock { () -> Reply? in
            Self.requestCounts[host, default: 0] += 1
            return Self.replies[host]?[path]
        }
        let resolved = reply ?? Reply(status: 404, body: "")
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: resolved.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/xml; charset=utf-8"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(resolved.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Fixtures

/// One child row of a multistatus body.
private struct StubChild {
    var href: String
    var isCollection: Bool
}

/// An Apache mod_dav-shaped `207`: properties come back under a second `lp1:`
/// prefix that is also bound to `DAV:`, and the collection itself is the first
/// `<D:response>`.
private func multistatus(selfHref: String, children: [StubChild]) -> String {
    func response(_ href: String, isCollection: Bool) -> String {
        let resourcetype = isCollection
            ? "<lp1:resourcetype><D:collection/></lp1:resourcetype>"
            : "<lp1:resourcetype/><lp1:getcontentlength>2806609208</lp1:getcontentlength>"
        return """
        <D:response xmlns:lp1="DAV:">
        <D:href>\(href)</D:href>
        <D:propstat>
        <D:prop>
        \(resourcetype)
        <lp1:getlastmodified>Mon, 01 Sep 2025 10:00:00 GMT</lp1:getlastmodified>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
        </D:response>
        """
    }
    let body = ([response(selfHref, isCollection: true)] + children.map {
        response($0.href, isCollection: $0.isCollection)
    }).joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
    \(body)
    </D:multistatus>
    """
}

private func collection(_ selfHref: String, _ children: [StubChild]) -> WebDAVTreeStubProtocol.Reply {
    WebDAVTreeStubProtocol.Reply(status: 207, body: multistatus(selfHref: selfHref, children: children))
}

// MARK: - Tests

struct WebDAVSyncTests {
    /// The listing fingerprint is device-local `UserDefaults` state that
    /// outlives a test, so every case starts without one — otherwise a suite
    /// re-run could meet its own fingerprint and skip the import it asserts on.
    init() {
        clearWebDAVDigests()
    }

    private func makeManager(container: ModelContainer) -> ContentSyncManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WebDAVTreeStubProtocol.self]
        let client = WebDAVClient(urlSession: URLSession(configuration: config))
        return ContentSyncManager(modelContainer: container, webdavClient: client)
    }

    private func makePlaylist(container: ModelContainer, url: String) throws -> Playlist {
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test WebDAV", webdavURL: url, username: "bilipp", password: "test")
        context.insert(playlist)
        try context.save()
        return playlist
    }

    /// A host nobody else in the suite uses, so the stub's routing table is
    /// private to this test even under parallel execution.
    private func uniqueHost() -> String {
        "webdav-\(UUID().uuidString.prefix(8).lowercased()).test"
    }

    // MARK: Full tree

    @Test func `walks a nested share into movies, episodes and categories`() async throws {
        let host = uniqueHost()
        defer { WebDAVTreeStubProtocol.remove(host: host) }
        let episodeFile = "Harbor.Lights.S02E01.1080p.WEB.h264-NIGHT%5BIndexer.to%5D.mkv"
        WebDAVTreeStubProtocol.install(host: host, replies: [
            "/Movies/": collection("/Movies/", [
                StubChild(href: "/Movies/Action/", isCollection: true),
                StubChild(href: "/Movies/Shows/", isCollection: true),
                StubChild(href: "/Movies/Blade%20Runner%202049.mkv", isCollection: false)
            ]),
            "/Movies/Action/": collection("/Movies/Action/", [
                StubChild(href: "/Movies/Action/The.Godfather.1972.1080p.BluRay.x264-GROUP.mkv", isCollection: false),
                StubChild(href: "/Movies/Action/poster.jpg", isCollection: false)
            ]),
            "/Movies/Shows/": collection("/Movies/Shows/", [
                StubChild(href: "/Movies/Shows/\(episodeFile)", isCollection: false)
            ])
        ])

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, url: "http://\(host)/Movies/")
        let playlistId = playlist.id
        try await makeManager(container: container).syncPlaylist(playlist)

        let context = ModelContext(container)
        let movies = try context.fetch(FetchDescriptor<Movie>())
        #expect(Set(movies.map(\.name)) == ["Blade Runner 2049", "The Godfather 1972"])
        let godfather = try #require(movies.first { $0.name == "The Godfather 1972" })
        #expect(godfather.categoryId == "\(playlistId.uuidString)-vod-Movies")
        // The server's own percent-encoding is preserved: re-encoding would turn
        // %20 into %2520 and every playback request would 404.
        #expect(godfather.directURL == "http://\(host)/Movies/Action/The.Godfather.1972.1080p.BluRay.x264-GROUP.mkv")
        let blade = try #require(movies.first { $0.name == "Blade Runner 2049" })
        #expect(blade.categoryId == "\(playlistId.uuidString)-vod-Movies")
        #expect(blade.directURL == "http://\(host)/Movies/Blade%20Runner%202049.mkv")

        // The filename's SxxExx token decides series-vs-movie, whatever the
        // folder is called.
        let series = try context.fetch(FetchDescriptor<Series>())
        #expect(series.count == 1)
        let show = try #require(series.first)
        #expect(show.name == "Harbor Lights")
        #expect(show.categoryId == "\(playlistId.uuidString)-series-Movies")
        #expect(show.episodes.count == 1)
        let episode = try #require(show.episodes.first)
        #expect(episode.seasonNum == 2)
        #expect(episode.episodeNum == 1)
        #expect(episode.title.isEmpty)
        #expect(episode.directSource == "http://\(host)/Movies/Shows/\(episodeFile)")

        // A file share has no live channels, and a non-media file is skipped
        // rather than filed as one.
        #expect(try context.fetch(FetchDescriptor<LiveStream>()).isEmpty)

        let categories = try context.fetch(FetchDescriptor<Lume.Category>())
        #expect(Set(categories.map(\.name)) == ["Movies"])
        #expect(categories.allSatisfy { $0.type != .live })

        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.syncStatus == .idle)
        #expect(stored.lastSyncDate != nil)
    }

    // MARK: Per-episode subfolders

    @Test func `episodes in own subfolders cluster into one series and one category`() async throws {
        let host = uniqueHost()
        defer { WebDAVTreeStubProtocol.remove(host: host) }
        let secondFolder = "Harbor.Lights.S02E02.1080p.WEB.h264-NIGHT%5BIndexer.to%5D"
        let thirdFolder = "Harbor.Lights.S02E03.1080p.WEB.h264-NIGHT%5BIndexer.to%5D"
        WebDAVTreeStubProtocol.install(host: host, replies: [
            "/Movies/": collection("/Movies/", [
                StubChild(
                    href: "/Movies/Harbor.Lights.S02E01.1080p.WEB.h264-NIGHT%5BIndexer.to%5D.mkv",
                    isCollection: false
                ),
                StubChild(href: "/Movies/\(secondFolder)/", isCollection: true),
                StubChild(href: "/Movies/\(thirdFolder)/", isCollection: true)
            ]),
            "/Movies/\(secondFolder)/": collection("/Movies/\(secondFolder)/", [
                StubChild(
                    href: "/Movies/\(secondFolder)/Harbor.Lights.S02E02.1080p.WEB.h264-NIGHT%5BIndexer.to%5D.mkv",
                    isCollection: false
                )
            ]),
            "/Movies/\(thirdFolder)/": collection("/Movies/\(thirdFolder)/", [
                StubChild(href: "/Movies/\(thirdFolder)/video.mkv", isCollection: false)
            ])
        ])

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, url: "http://\(host)/Movies/")
        let playlistId = playlist.id
        try await makeManager(container: container).syncPlaylist(playlist)

        let context = ModelContext(container)
        let series = try context.fetch(FetchDescriptor<Series>())
        #expect(series.count == 1)
        let show = try #require(series.first)
        #expect(show.name == "Harbor Lights")
        #expect(show.categoryId == "\(playlistId.uuidString)-series-Movies")
        #expect(show.episodes.count == 3)
        #expect(Set(show.episodes.map(\.episodeNum)) == [1, 2, 3])
        #expect(show.episodes.allSatisfy { $0.seasonNum == 2 })

        #expect(try context.fetch(FetchDescriptor<Movie>()).isEmpty)

        let categories = try context.fetch(FetchDescriptor<Lume.Category>())
        #expect(categories.count == 1)
        #expect(categories.first?.name == "Movies")
        #expect(categories.first?.type == .series)
    }

    // MARK: Cycles

    @Test func `a symlinked directory cycle terminates`() async throws {
        let host = uniqueHost()
        defer { WebDAVTreeStubProtocol.remove(host: host) }
        WebDAVTreeStubProtocol.install(host: host, replies: [
            "/Share/": collection("/Share/", [
                StubChild(href: "/Share/A/", isCollection: true)
            ]),
            // `A/B/latest` is a symlink back to `A`, and `A` also links to
            // itself: both must be recognised as already visited.
            "/Share/A/": collection("/Share/A/", [
                StubChild(href: "/Share/A/B/", isCollection: true),
                StubChild(href: "/Share/A/", isCollection: true),
                StubChild(href: "/Share/A/Movie.One.2019.1080p.mkv", isCollection: false)
            ]),
            "/Share/A/B/": collection("/Share/A/B/", [
                StubChild(href: "/Share/A/", isCollection: true),
                StubChild(href: "/Share/", isCollection: true)
            ])
        ])

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, url: "http://\(host)/Share")
        try await makeManager(container: container).syncPlaylist(playlist)

        // Three directories, one PROPFIND each. Without the visited set this
        // never returns.
        #expect(WebDAVTreeStubProtocol.requestCount(host: host) == 3)
        let context = ModelContext(container)
        let movies = try context.fetch(FetchDescriptor<Movie>())
        #expect(movies.count == 1)
        #expect(movies.first?.name == "Movie One 2019")
    }

    // MARK: Partial walk

    /// `One` holds a full import batch, so the first sync's catalog spans more
    /// than one batch and the second sync has real rows to lose. The walk runs
    /// to completion before anything is imported, so the failing second walk
    /// writes nothing at all — what is under test is that it also prunes
    /// nothing: the coverage gate alone would wave a sweep through, and only
    /// the walk-completed gate keeps `Beta` and the favorites and watch
    /// progress keyed to it.
    @Test func `a walk that fails midway keeps every row and never prunes`() async throws {
        let host = uniqueHost()
        defer { WebDAVTreeStubProtocol.remove(host: host) }
        let batch = (0 ..< WebDAVWalkProducer.batchSize).map { index in
            StubChild(href: String(format: "/Share/One/Film.%04d.2001.1080p.mkv", index), isCollection: false)
        }
        let fullTree: [String: WebDAVTreeStubProtocol.Reply] = [
            "/Share/": collection("/Share/", [
                StubChild(href: "/Share/One/", isCollection: true),
                StubChild(href: "/Share/Two/", isCollection: true)
            ]),
            "/Share/One/": collection("/Share/One/", batch),
            "/Share/Two/": collection("/Share/Two/", [
                StubChild(href: "/Share/Two/Beta.2002.1080p.mkv", isCollection: false)
            ])
        ]
        WebDAVTreeStubProtocol.install(host: host, replies: fullTree)

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, url: "http://\(host)/Share/")
        let manager = makeManager(container: container)
        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == WebDAVWalkProducer.batchSize + 1)

        // Second sync: `One` still lists its batch, `Two` dies. Beta is now
        // absent from everything the walk saw.
        var brokenTree = fullTree
        brokenTree["/Share/Two/"] = WebDAVTreeStubProtocol.Reply(status: 500, body: "")
        WebDAVTreeStubProtocol.install(host: host, replies: brokenTree)

        await #expect(throws: WebDAVError.self) {
            try await manager.syncPlaylist(playlist)
        }

        let after = ModelContext(container)
        #expect(try after.fetchCount(FetchDescriptor<Movie>()) == WebDAVWalkProducer.batchSize + 1)
        #expect(try after.fetch(FetchDescriptor<Movie>()).contains { $0.name == "Beta 2002" })
        #expect(try after.fetchCount(FetchDescriptor<Lume.Category>()) == 1)
        let stored = try #require(try after.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.syncStatus == .error)
    }
}

//
//  WebDAVDigestSkipTests.swift
//  LumeTests
//
//  Skip-if-unchanged for the WebDAV pipeline: a re-walk whose listing matches
//  the one this device last imported in full must skip the import and the
//  sweeps, while still advancing the playlist's sync dates. A walk that dies
//  partway must leave no fingerprint at all.
//
//  Its own file rather than more of WebDAVSyncTests, whose stub serves a fixed
//  body per path where these cases need per-file etag/size/mtime control.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

// MARK: - Stub server

/// Serves canned `207` bodies per path, keyed by host so two suites can never
/// collide. Private to this file and installed only on the session handed to
/// `WebDAVClient` — never through `URLProtocol.registerClass`.
private final nonisolated class WebDAVDigestStubProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var replies: [String: [String: Reply]] = [:]

    static func install(host: String, replies: [String: Reply]) {
        lock.withLock { Self.replies[host] = replies }
    }

    static func remove(host: String) {
        lock.withLock { replies[host] = nil }
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
        let reply = Self.lock.withLock { Self.replies[host]?[path] } ?? Reply(status: 404, body: "")
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/xml; charset=utf-8"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Fixtures

/// One media file in a stubbed listing, with the three properties the
/// fingerprint is taken over.
private struct StubFile {
    var href: String
    var etag: String? = "\"aaa111\""
    var length: Int64 = 1000
    var lastModified: String = "Mon, 01 Sep 2025 10:00:00 GMT"
}

private func multistatus(selfHref: String, directories: [String], files: [StubFile]) -> String {
    func collectionResponse(_ href: String) -> String {
        """
        <D:response xmlns:lp1="DAV:">
        <D:href>\(href)</D:href>
        <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        """
    }
    func fileResponse(_ file: StubFile) -> String {
        let etag = file.etag.map { "<D:getetag>\($0)</D:getetag>" } ?? ""
        return """
        <D:response xmlns:lp1="DAV:">
        <D:href>\(file.href)</D:href>
        <D:propstat><D:prop>
        <lp1:resourcetype/>
        <lp1:getcontentlength>\(file.length)</lp1:getcontentlength>
        <lp1:getlastmodified>\(file.lastModified)</lp1:getlastmodified>
        \(etag)
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        """
    }
    let body = ([collectionResponse(selfHref)]
        + directories.map(collectionResponse)
        + files.map(fileResponse)).joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
    \(body)
    </D:multistatus>
    """
}

private func collection(
    _ selfHref: String,
    directories: [String] = [],
    files: [StubFile] = []
) -> WebDAVDigestStubProtocol.Reply {
    WebDAVDigestStubProtocol.Reply(
        status: 207,
        body: multistatus(selfHref: selfHref, directories: directories, files: files)
    )
}

// MARK: - Tests

struct WebDAVDigestSkipTests {
    /// Swift Testing runs this before every test in the suite. The listing
    /// fingerprint is device-local `UserDefaults` state that outlives a test, so
    /// each case starts from a clean slate rather than inheriting a sibling's.
    init() {
        clearWebDAVDigests()
    }

    // MARK: Helpers

    private func makeManager(container: ModelContainer) -> ContentSyncManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WebDAVDigestStubProtocol.self]
        return ContentSyncManager(
            modelContainer: container,
            webdavClient: WebDAVClient(urlSession: URLSession(configuration: config))
        )
    }

    private func makePlaylist(container: ModelContainer, url: String) throws -> Playlist {
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test WebDAV", webdavURL: url, username: "u", password: "p")
        context.insert(playlist)
        try context.save()
        return playlist
    }

    private func uniqueHost() -> String {
        "webdav-digest-\(UUID().uuidString.prefix(8).lowercased()).test"
    }

    /// The fingerprint and the sweep counters live in `UserDefaults`, which
    /// outlives the store — every case clears its own keys so none leaks.
    private func clearDefaults(playlistId: UUID) {
        WebDAVDigestStore.remove(playlistId: playlistId)
        SweepSkipDefaults.removeAll(playlistId: playlistId)
    }

    private var alphaAndBeta: [String: WebDAVDigestStubProtocol.Reply] {
        [
            "/Share/": collection("/Share/", files: [
                StubFile(href: "/Share/Alpha.2001.1080p.mkv"),
                StubFile(href: "/Share/Beta.2002.1080p.mkv")
            ])
        ]
    }

    /// Removes one imported movie behind the sync's back. A skipped import
    /// leaves the hole; an import that actually ran fills it back in.
    private func deleteAlpha(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let movie = try #require(
            try context.fetch(FetchDescriptor<Movie>()).first { $0.name == "Alpha 2001" }
        )
        context.delete(movie)
        try context.save()
    }

    private func hasAlpha(in container: ModelContainer) throws -> Bool {
        try ModelContext(container).fetch(FetchDescriptor<Movie>()).contains { $0.name == "Alpha 2001" }
    }

    // MARK: Tests

    @Test func `an unchanged listing skips the import`() async throws {
        let host = uniqueHost()
        defer { WebDAVDigestStubProtocol.remove(host: host) }
        WebDAVDigestStubProtocol.install(host: host, replies: alphaAndBeta)

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, url: "http://\(host)/Share/")
        let playlistId = playlist.id
        defer { clearDefaults(playlistId: playlistId) }

        let manager = makeManager(container: container)
        try await manager.syncPlaylist(playlist)
        #expect(
            WebDAVDigestStore.digest(playlistId: playlistId) != nil,
            "A completed walk and import must be fingerprinted"
        )

        try deleteAlpha(in: container)
        try await manager.syncPlaylist(playlist)

        #expect(try hasAlpha(in: container) == false, "An unchanged listing must skip the import entirely")
        // The sweeps are skipped with it: Beta, which the listing still names,
        // is untouched.
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Movie>()) == 1)
    }

    @Test func `a changed etag imports again`() async throws {
        let host = uniqueHost()
        defer { WebDAVDigestStubProtocol.remove(host: host) }
        WebDAVDigestStubProtocol.install(host: host, replies: alphaAndBeta)

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, url: "http://\(host)/Share/")
        let playlistId = playlist.id
        defer { clearDefaults(playlistId: playlistId) }

        let manager = makeManager(container: container)
        try await manager.syncPlaylist(playlist)
        try deleteAlpha(in: container)

        // Same files, same sizes, same dates — one new etag. The share was
        // re-encoded in place, which no href-only fingerprint would notice.
        WebDAVDigestStubProtocol.install(host: host, replies: [
            "/Share/": collection("/Share/", files: [
                StubFile(href: "/Share/Alpha.2001.1080p.mkv", etag: "\"bbb222\""),
                StubFile(href: "/Share/Beta.2002.1080p.mkv")
            ])
        ])
        try await manager.syncPlaylist(playlist)

        #expect(try hasAlpha(in: container), "A changed etag must re-import")
    }

    @Test func `a changed size or modification date imports again`() async throws {
        let host = uniqueHost()
        defer { WebDAVDigestStubProtocol.remove(host: host) }
        WebDAVDigestStubProtocol.install(host: host, replies: alphaAndBeta)

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, url: "http://\(host)/Share/")
        let playlistId = playlist.id
        defer { clearDefaults(playlistId: playlistId) }

        let manager = makeManager(container: container)
        try await manager.syncPlaylist(playlist)
        let first = try #require(WebDAVDigestStore.digest(playlistId: playlistId))

        WebDAVDigestStubProtocol.install(host: host, replies: [
            "/Share/": collection("/Share/", files: [
                StubFile(href: "/Share/Alpha.2001.1080p.mkv", length: 2000),
                StubFile(
                    href: "/Share/Beta.2002.1080p.mkv",
                    lastModified: "Tue, 02 Sep 2025 10:00:00 GMT"
                )
            ])
        ])
        try deleteAlpha(in: container)
        try await manager.syncPlaylist(playlist)

        #expect(try hasAlpha(in: container), "A changed size must re-import")
        #expect(
            WebDAVDigestStore.digest(playlistId: playlistId) != first,
            "The new listing must be fingerprinted in place of the old one"
        )
    }

    @Test func `a share listed in a different order still skips`() async throws {
        let host = uniqueHost()
        defer { WebDAVDigestStubProtocol.remove(host: host) }
        WebDAVDigestStubProtocol.install(host: host, replies: alphaAndBeta)

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, url: "http://\(host)/Share/")
        let playlistId = playlist.id
        defer { clearDefaults(playlistId: playlistId) }

        let manager = makeManager(container: container)
        try await manager.syncPlaylist(playlist)
        try deleteAlpha(in: container)

        // Nothing changed but the order the server happened to list the
        // directory in; the fingerprint sorts, so this is not a change.
        WebDAVDigestStubProtocol.install(host: host, replies: [
            "/Share/": collection("/Share/", files: [
                StubFile(href: "/Share/Beta.2002.1080p.mkv"),
                StubFile(href: "/Share/Alpha.2001.1080p.mkv")
            ])
        ])
        try await manager.syncPlaylist(playlist)

        #expect(try hasAlpha(in: container) == false, "Listing order is not a content change")
    }

    @Test func `a walk that fails partway records no fingerprint`() async throws {
        let host = uniqueHost()
        defer { WebDAVDigestStubProtocol.remove(host: host) }
        WebDAVDigestStubProtocol.install(host: host, replies: [
            "/Share/": collection("/Share/", directories: ["/Share/Sub/"], files: [
                StubFile(href: "/Share/Alpha.2001.1080p.mkv")
            ]),
            "/Share/Sub/": WebDAVDigestStubProtocol.Reply(status: 500, body: "")
        ])

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, url: "http://\(host)/Share/")
        let playlistId = playlist.id
        defer { clearDefaults(playlistId: playlistId) }

        let manager = makeManager(container: container)
        await #expect(throws: WebDAVError.self) {
            try await manager.syncPlaylist(playlist)
        }

        #expect(
            WebDAVDigestStore.digest(playlistId: playlistId) == nil,
            "A partial walk names only part of the share — fingerprinting it would skip the import it never ran"
        )

        // And the next sync, once the share answers again, really does import.
        WebDAVDigestStubProtocol.install(host: host, replies: [
            "/Share/": collection("/Share/", directories: ["/Share/Sub/"], files: [
                StubFile(href: "/Share/Alpha.2001.1080p.mkv")
            ]),
            "/Share/Sub/": collection("/Share/Sub/", files: [
                StubFile(href: "/Share/Sub/Beta.2002.1080p.mkv")
            ])
        ])
        try await manager.syncPlaylist(playlist)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Movie>()) == 2)
    }

    @Test func `an empty share is not fingerprinted`() async throws {
        let host = uniqueHost()
        defer { WebDAVDigestStubProtocol.remove(host: host) }
        WebDAVDigestStubProtocol.install(host: host, replies: ["/Share/": collection("/Share/")])

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, url: "http://\(host)/Share/")
        let playlistId = playlist.id
        defer { clearDefaults(playlistId: playlistId) }

        try await makeManager(container: container).syncPlaylist(playlist)

        // A misconfigured path looks exactly like this; fingerprinting it would
        // turn every later retry into an instant no-op.
        #expect(WebDAVDigestStore.digest(playlistId: playlistId) == nil)
    }

    @Test func `a skipped sync still advances the playlist dates`() async throws {
        let host = uniqueHost()
        defer { WebDAVDigestStubProtocol.remove(host: host) }
        WebDAVDigestStubProtocol.install(host: host, replies: alphaAndBeta)

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, url: "http://\(host)/Share/")
        let playlistId = playlist.id
        defer { clearDefaults(playlistId: playlistId) }

        let manager = makeManager(container: container)
        try await manager.syncPlaylist(playlist)

        let backdated = Date.distantPast
        do {
            let context = ModelContext(container)
            let stored = try #require(
                try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })).first
            )
            stored.lastUpdated = backdated
            stored.lastSyncDate = backdated
            try context.save()
        }

        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)
        let stored = try #require(
            try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })).first
        )
        #expect(stored.lastUpdated ?? backdated > backdated, "A skipped sync did succeed — lastUpdated must advance")
        #expect(stored.lastSyncDate ?? backdated > backdated, "A skipped sync did succeed — lastSyncDate must advance")
    }
}

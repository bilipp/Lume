//
//  MediaServerShowEpisodesTests.swift
//  LumeTests
//
//  A Jellyfin/Emby show's episodes fetched per show, when it is opened — the
//  path AIOStreams-style servers need, since they list a library's series but
//  answer a library-wide episode query with nothing. A stubbed server is
//  synced through the real ContentSyncManager into an in-memory store.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

/// Canned Jellyfin JSON keyed by path (item queries also by `ParentId` and
/// `IncludeItemTypes`). A reply can demand a session token, answering 401 to
/// any other — how a revoked token looks to the client.
private final nonisolated class ShowEpisodesStubProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var body: String
        var requiredToken: String?
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
        var reply = Self.lock.withLock { Self.replies[host]?[Self.route(url)] } ?? Reply(status: 404, body: "")
        if let token = reply.requiredToken,
           request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"\(token)\"") != true
        {
            reply = Reply(status: 401, body: "")
        }
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func route(_ url: URL) -> String {
        guard url.path.hasSuffix("/Items"),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return url.path }
        let parent = query.first { $0.name == "ParentId" }?.value ?? ""
        let types = query.first { $0.name == "IncludeItemTypes" }?.value ?? ""
        return "\(url.path)|\(parent)|\(types)"
    }
}

private func page(_ items: [String]) -> String {
    #"{"Items": [\#(items.joined(separator: ","))], "TotalRecordCount": \#(items.count)}"#
}

private let showShell = #"{"Id": "s1", "Name": "Harbor Lights", "Type": "Series", "ImageTags": {"Primary": "stag"}}"#

private func episode(_ id: String, season: Int, number: Int, extra: String = "") -> String {
    """
    {"Id": "\(id)", "Name": "Episode \(number)", "Type": "Episode", "SeriesId": "s1", "SeriesName": "Harbor Lights",
     "SeasonId": "season\(season)", "ParentIndexNumber": \(season), "IndexNumber": \(number),
     "RunTimeTicks": 27000000000, "PremiereDate": "2024-02-0\(number)T00:00:00.0000000Z",
     "Overview": "Plot \(number).", "SeriesPrimaryImageTag": "stag"\(extra)}
    """
}

struct MediaServerShowEpisodesTests {
    private func uniqueHost() -> String {
        "aio-\(UUID().uuidString.prefix(8).lowercased()).test"
    }

    private func makeManager(container: ModelContainer) -> ContentSyncManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ShowEpisodesStubProtocol.self]
        return ContentSyncManager(modelContainer: container, jellyfinClient: JellyfinClient(urlSession: URLSession(configuration: config)))
    }

    private func makePlaylist(container: ModelContainer, host: String) throws -> Playlist {
        let context = ModelContext(container)
        let playlist = Playlist(name: "AIOStreams", serverURL: "http://\(host)", username: "bilipp", password: "test")
        playlist.sourceType = .jellyfin
        context.insert(playlist)
        try context.save()
        return playlist
    }

    /// A server that lists its show under the library but no episodes there —
    /// only per show, as AIOStreams does.
    private func installPerShowServer(host: String, token: String = "sess", episodesToken: String? = nil) {
        ShowEpisodesStubProtocol.install(host: host, replies: [
            "/Users/AuthenticateByName": .init(body: #"{"AccessToken": "\#(token)", "User": {"Id": "user1"}}"#),
            "/Users/user1/Views": .init(body: #"{"Items": [{"Id": "libShows", "Name": "Shows", "CollectionType": "tvshows"}], "TotalRecordCount": 1}"#),
            "/Users/user1/Items|libShows|Series": .init(body: page([showShell])),
            "/Users/user1/Items|libShows|Episode": .init(body: page([])),
            "/Shows/s1/Episodes": .init(
                body: page([
                    episode("e1", season: 1, number: 1),
                    episode("e2", season: 1, number: 2),
                    episode("e3", season: 2, number: 1, extra: #", "LocationType": "Virtual""#)
                ]),
                requiredToken: episodesToken
            )
        ])
    }

    @Test func `an opened show fetches its episodes per show, keyed like the sync`() async throws {
        let host = uniqueHost()
        defer { ShowEpisodesStubProtocol.remove(host: host) }
        installPerShowServer(host: host)
        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        let manager = makeManager(container: container)
        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)
        let show = try #require(try context.fetch(FetchDescriptor<Series>()).first)
        #expect(show.episodes.isEmpty)
        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.supportsPerSeriesEpisodeFetch)
        // Shows listed without their episodes: the server has no files of its
        // own to download.
        #expect(stored.resolvesSourcesOnDemand == true)
        #expect(!stored.supportsDownloads)

        let parsed = try await manager.fetchEpisodes(seriesId: show.seriesId, seriesElementId: show.id, playlist: stored)
        let prefix = "\(playlist.id.uuidString)-jellyfin-"
        // The unaired (virtual) episode has nothing to play and is left out.
        #expect(parsed.map(\.id) == [prefix + "episode-e1", prefix + "episode-e2"])
        let first = try #require(parsed.first)
        #expect(first.seasonNum == 1)
        #expect(first.episodeNum == 1)
        #expect(first.directSource == "http://\(host)/Videos/e1/stream?Static=true")
        #expect(first.durationSecs == 2700)
        #expect(first.airDate == "2024-02-01")
        // No still of its own: the show's poster stands in.
        #expect(first.movieImage?.contains("/Items/s1/Images/Primary") == true)
    }

    @Test func `a server that lists its episodes keeps offering downloads`() async throws {
        let host = uniqueHost()
        defer { ShowEpisodesStubProtocol.remove(host: host) }
        ShowEpisodesStubProtocol.install(host: host, replies: [
            "/Users/AuthenticateByName": .init(body: #"{"AccessToken": "sess", "User": {"Id": "user1"}}"#),
            "/Users/user1/Views": .init(body: #"{"Items": [{"Id": "libShows", "Name": "Shows", "CollectionType": "tvshows"}], "TotalRecordCount": 1}"#),
            "/Users/user1/Items|libShows|Series": .init(body: page([showShell])),
            "/Users/user1/Items|libShows|Episode": .init(body: page([episode("e1", season: 1, number: 1)]))
        ])
        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        try await makeManager(container: container).syncPlaylist(playlist)

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.resolvesSourcesOnDemand == false)
        #expect(stored.supportsDownloads)
    }

    @Test func `a later sync keeps the episodes a show fetched for itself`() async throws {
        let host = uniqueHost()
        defer { ShowEpisodesStubProtocol.remove(host: host) }
        installPerShowServer(host: host)
        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        let manager = makeManager(container: container)
        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)
        let show = try #require(try context.fetch(FetchDescriptor<Series>()).first)
        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        let parsed = try await manager.fetchEpisodes(seriesId: show.seriesId, seriesElementId: show.id, playlist: stored)
        show.insertEpisodes(parsed, into: context)
        #expect(show.episodes.count == 2)

        // The library still reports no episodes; the sweep must not read that
        // as "every episode was removed".
        try await manager.syncPlaylist(stored)
        let after = try ModelContext(container).fetch(FetchDescriptor<Episode>())
        #expect(after.count == 2)
    }

    @Test func `a revoked session signs in again for the episode fetch`() async throws {
        let host = uniqueHost()
        defer { ShowEpisodesStubProtocol.remove(host: host) }
        installPerShowServer(host: host, token: "fresh", episodesToken: "fresh")
        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        playlist.jellyfinAccessToken = "revoked"
        playlist.jellyfinUserId = "user1"

        let show = Series(id: "\(playlist.id.uuidString)-jellyfin-s1", seriesId: 1, name: "Harbor Lights")
        let parsed = try await makeManager(container: container)
            .fetchEpisodes(seriesId: show.seriesId, seriesElementId: show.id, playlist: playlist)
        #expect(parsed.count == 2)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.jellyfinAccessToken == "fresh")
    }

    @Test func `a shell with no server item behind it fetches nothing`() {
        let prefix = "P-jellyfin-"
        #expect(ContentSyncManager.mediaServerSeriesItemId(seriesElementId: "P-jellyfin-s1", prefix: prefix) == "s1")
        #expect(ContentSyncManager.mediaServerSeriesItemId(seriesElementId: "P-jellyfin-name-123", prefix: prefix) == nil)
        #expect(ContentSyncManager.mediaServerSeriesItemId(seriesElementId: "P-emby-s1", prefix: prefix) == nil)
    }
}

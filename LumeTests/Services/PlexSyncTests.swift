//
//  PlexSyncTests.swift
//  LumeTests
//
//  End-to-end tests for the Plex sync pipeline: a stubbed server (identity,
//  sections, section pages) is synced through the real ContentSyncManager
//  into an in-memory store.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

// MARK: - Stub server

/// Serves canned Plex JSON per endpoint, routing section queries on their
/// `type` query item.
///
/// Keyed by a per-test host so parallel suites can never collide. Registered
/// only on the session handed to `PlexClient`, never globally.
private final nonisolated class PlexServerStubProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
        /// When true, a request without an `X-Plex-Token` gets a 401.
        var requiresToken: Bool = false
        /// When set, only this exact token is accepted — anything else 401s,
        /// which is how a revoked token is modelled.
        var acceptedToken: String?
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
        let reply = Self.lock.withLock { Self.replies[host]?[Self.route(url)] } ?? Reply(status: 404, body: "")
        let sent = request.value(forHTTPHeaderField: "X-Plex-Token")
        let accepted: Bool = if let expected = reply.acceptedToken {
            sent == expected
        } else {
            !reply.requiresToken || sent != nil
        }
        let status = accepted ? reply.status : 401
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `/library/sections`, or `/library/sections/{key}/all|{type}`.
    private static func route(_ url: URL) -> String {
        let path = url.path
        guard path.hasSuffix("/all"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let type = components.queryItems?.first(where: { $0.name == "type" })?.value
        else { return path }
        return "\(path)|\(type)"
    }
}

// MARK: - Fixtures

private func plexMovie(ratingKey: String, title: String) -> String {
    """
    {"ratingKey": "\(ratingKey)", "type": "movie", "title": "\(title)",
     "summary": "Summary of \(title).", "year": 2007, "rating": 7.8,
     "contentRating": "PG-13", "duration": 8294507, "addedAt": 1789592930,
     "originallyAvailableAt": "2007-07-11",
     "thumb": "/library/metadata/\(ratingKey)/thumb/17",
     "Media": [{"container": "mp4", "Part": [{"key": "/library/parts/\(ratingKey)/17/file.mp4", "container": "mp4"}]}],
     "Genre": [{"tag": "Fantasy"}],
     "Guid": [{"id": "imdb://tt0373889"}, {"id": "tmdb://675"}]}
    """
}

private func plexShow(ratingKey: String, title: String) -> String {
    """
    {"ratingKey": "\(ratingKey)", "type": "show", "title": "\(title)",
     "summary": "Summary of \(title).", "year": 2025, "rating": 6.5,
     "originallyAvailableAt": "2025-01-01",
     "thumb": "/library/metadata/\(ratingKey)/thumb/18",
     "Genre": [{"tag": "Reality"}],
     "Guid": [{"id": "tmdb://253030"}]}
    """
}

/// The show title is derived rather than passed: every fixture episode
/// belongs to `plexShow`, so a sixth parameter would only restate it.
private func plexEpisode(ratingKey: String, title: String, showKey: String, season: Int, number: Int) -> String {
    """
    {"ratingKey": "\(ratingKey)", "type": "episode", "title": "\(title)",
     "grandparentRatingKey": "\(showKey)", "grandparentTitle": "Harbor Lights",
     "parentIndex": \(season), "index": \(number), "duration": 3648704,
     "summary": "Summary of \(title).",
     "thumb": "/library/metadata/\(ratingKey)/thumb/19",
     "Media": [{"container": "mkv", "Part": [{"key": "/library/parts/\(ratingKey)/19/file.mkv"}]}]}
    """
}

private func plexPage(_ items: [String], total: Int) -> PlexServerStubProtocol.Reply {
    PlexServerStubProtocol.Reply(status: 200, body: """
    {"MediaContainer": {"size": \(items.count), "totalSize": \(total), "Metadata": [\(items.joined(separator: ","))]}}
    """)
}

// MARK: - Tests

struct PlexSyncTests {
    private func uniqueHost() -> String {
        "plex-\(UUID().uuidString.prefix(8).lowercased()).test"
    }

    private func makeManager(container: ModelContainer) -> ContentSyncManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlexServerStubProtocol.self]
        let client = PlexClient(urlSession: URLSession(configuration: config))
        return ContentSyncManager(modelContainer: container, plexClient: client)
    }

    private func makePlaylist(container: ModelContainer, host: String, token: String? = nil, username: String = "", password: String = "") throws -> Playlist {
        let context = ModelContext(container)
        let playlist = Playlist(
            name: "Test Plex", serverURL: "http://\(host):32400",
            username: username, password: password
        )
        playlist.sourceType = .plex
        playlist.plexAccessToken = token
        context.insert(playlist)
        try context.save()
        return playlist
    }

    private func installFullServer(
        host: String, movies: [String], shows: [String], episodes: [String],
        requiresToken: Bool = false, acceptedToken: String? = nil
    ) {
        PlexServerStubProtocol.install(host: host, replies: [
            "/library/sections": .init(status: 200, body: """
            {"MediaContainer": {"size": 3, "Directory": [
              {"key": "1", "title": "Movies", "type": "movie"},
              {"key": "2", "title": "TV Shows", "type": "show"},
              {"key": "3", "title": "Music", "type": "artist"}
            ]}}
            """, requiresToken: requiresToken, acceptedToken: acceptedToken),
            "/library/sections/1/all|1": plexPage(movies, total: movies.count),
            "/library/sections/2/all|2": plexPage(shows, total: shows.count),
            "/library/sections/2/all|4": plexPage(episodes, total: episodes.count)
        ])
    }

    // MARK: Full sync

    @Test func `a full sync imports movies, shows, episodes and categories`() async throws {
        let host = uniqueHost()
        defer { PlexServerStubProtocol.remove(host: host) }
        installFullServer(
            host: host,
            movies: [plexMovie(ratingKey: "1", title: "Arrival")],
            shows: [plexShow(ratingKey: "3", title: "Harbor Lights")],
            episodes: [
                plexEpisode(ratingKey: "5", title: "Pilot", showKey: "3", season: 2, number: 1),
                plexEpisode(ratingKey: "6", title: "Tide", showKey: "3", season: 2, number: 2)
            ]
        )

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host, token: "tok")
        let playlistId = playlist.id
        try await makeManager(container: container).syncPlaylist(playlist)

        let context = ModelContext(container)
        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.plexAccessToken == "tok")
        #expect(stored.syncStatus == .idle)
        #expect(stored.lastSyncDate != nil)

        let movies = try context.fetch(FetchDescriptor<Movie>())
        #expect(movies.count == 1)
        let movie = try #require(movies.first)
        #expect(movie.name == "Arrival")
        #expect(movie.id == "\(playlistId.uuidString)-plex-1")
        #expect(movie.categoryId == "\(playlistId.uuidString)-vod-1")
        // Token-free stream URL; the image URL carries the token.
        #expect(movie.directURL == "http://\(host):32400/library/parts/1/17/file.mp4")
        #expect(movie.streamIcon?.contains("/library/metadata/1/thumb/17") == true)
        #expect(movie.streamIcon?.contains("X-Plex-Token=tok") == true)
        #expect(movie.rating == 7.8)
        #expect(movie.genre == "Fantasy")
        #expect(movie.tmdb == "675")
        #expect(movie.imdbId == "tt0373889")
        #expect(movie.releaseDate == "2007-07-11")
        #expect(movie.durationSecs == 8294)

        try expectShowImported(in: context, playlistId: playlistId, host: host)

        // One category per imported section; the music section is skipped.
        let categories = try context.fetch(FetchDescriptor<Lume.Category>())
        #expect(Set(categories.map(\.name)) == ["Movies", "TV Shows"])
        #expect(categories.allSatisfy { $0.type != .live })
        #expect(try context.fetch(FetchDescriptor<LiveStream>()).isEmpty)
    }

    private func expectShowImported(in context: ModelContext, playlistId: UUID, host: String) throws {
        let series = try context.fetch(FetchDescriptor<Series>())
        #expect(series.count == 1)
        let show = try #require(series.first)
        #expect(show.name == "Harbor Lights")
        #expect(show.categoryId == "\(playlistId.uuidString)-series-2")
        #expect(show.tmdb == "253030")
        #expect(show.episodes.count == 2)
        let pilot = try #require(show.episodes.first { $0.episodeNum == 1 })
        #expect(pilot.title == "Pilot")
        #expect(pilot.seasonNum == 2)
        #expect(pilot.directSource == "http://\(host):32400/library/parts/5/19/file.mkv")
        #expect(pilot.containerExtension == "mkv")
    }

    /// A server with "allow unauthenticated access on the local network" is a
    /// first-class setup, not a degraded one: it must sync with no token
    /// anywhere, including on the stored playlist.
    @Test func `a token-free server syncs and stores no credential`() async throws {
        let host = uniqueHost()
        defer { PlexServerStubProtocol.remove(host: host) }
        installFullServer(host: host, movies: [plexMovie(ratingKey: "1", title: "Arrival")], shows: [], episodes: [])

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        try await makeManager(container: container).syncPlaylist(playlist)

        let context = ModelContext(container)
        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.plexAccessToken == nil)
        let movie = try #require(try context.fetch(FetchDescriptor<Movie>()).first)
        #expect(movie.streamIcon?.contains("X-Plex-Token") == false)
    }

    // MARK: Prune

    @Test func `a second sync prunes removed titles and episodes`() async throws {
        let host = uniqueHost()
        defer { PlexServerStubProtocol.remove(host: host) }
        installFullServer(
            host: host,
            movies: [plexMovie(ratingKey: "1", title: "Arrival"), plexMovie(ratingKey: "2", title: "Gone")],
            shows: [plexShow(ratingKey: "3", title: "Harbor Lights")],
            episodes: [
                plexEpisode(ratingKey: "5", title: "Pilot", showKey: "3", season: 2, number: 1),
                plexEpisode(ratingKey: "6", title: "Tide", showKey: "3", season: 2, number: 2)
            ]
        )

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host, token: "tok")
        let manager = makeManager(container: container)
        try await manager.syncPlaylist(playlist)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Movie>()) == 2)

        installFullServer(
            host: host,
            movies: [plexMovie(ratingKey: "1", title: "Arrival")],
            shows: [plexShow(ratingKey: "3", title: "Harbor Lights")],
            episodes: [plexEpisode(ratingKey: "5", title: "Pilot", showKey: "3", season: 2, number: 1)]
        )
        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)
        let movies = try context.fetch(FetchDescriptor<Movie>())
        #expect(movies.map(\.name) == ["Arrival"])
        // The surviving show keeps its shell; only the dropped episode goes.
        let show = try #require(try context.fetch(FetchDescriptor<Series>()).first)
        #expect(show.episodes.map(\.episodeNum) == [1])
    }

    /// Plex rows must never be swept by the Jellyfin/Emby prune and vice
    /// versa — the only thing separating them under one playlist prefix is
    /// the infix.
    @Test func `a Plex prune leaves another source's rows under the same playlist alone`() async throws {
        let host = uniqueHost()
        defer { PlexServerStubProtocol.remove(host: host) }
        installFullServer(host: host, movies: [plexMovie(ratingKey: "1", title: "Arrival")], shows: [], episodes: [])

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host, token: "tok")
        let playlistId = playlist.id

        // A row written by a different pipeline under the same playlist.
        let seed = ModelContext(container)
        seed.insert(Movie(id: "\(playlistId.uuidString)-jellyfin-zz", streamId: 9, name: "Foreign"))
        try seed.save()

        try await makeManager(container: container).syncPlaylist(playlist)

        let names = try Set(ModelContext(container).fetch(FetchDescriptor<Movie>()).map(\.name))
        #expect(names == ["Arrival", "Foreign"])
    }

    // MARK: Authentication

    @Test func `credentials with no stored token are exchanged at plex tv`() async throws {
        let host = uniqueHost()
        let accountHost = "account-\(host)"
        defer {
            PlexServerStubProtocol.remove(host: host)
            PlexServerStubProtocol.remove(host: accountHost)
        }
        installFullServer(host: host, movies: [plexMovie(ratingKey: "1", title: "Arrival")], shows: [], episodes: [], requiresToken: true)
        PlexServerStubProtocol.install(host: accountHost, replies: [
            "/api/v2/users/signin": .init(status: 201, body: #"{"authToken": "acct-token"}"#)
        ])

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlexServerStubProtocol.self]
        let client = try PlexClient(
            urlSession: URLSession(configuration: config),
            accountBaseURL: #require(URL(string: "http://\(accountHost)"))
        )
        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host, username: "bilipp", password: "test")
        try await ContentSyncManager(modelContainer: container, plexClient: client).syncPlaylist(playlist)

        let context = ModelContext(container)
        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.plexAccessToken == "acct-token")
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 1)
    }

    /// A token the server has since revoked must not wedge the playlist: the
    /// sync signs in again rather than failing until the user edits it.
    @Test func `a revoked token is replaced by a fresh sign-in`() async throws {
        let host = uniqueHost()
        let accountHost = "account-\(host)"
        defer {
            PlexServerStubProtocol.remove(host: host)
            PlexServerStubProtocol.remove(host: accountHost)
        }
        // Only the token plex.tv is about to issue is accepted; the stored
        // one is stale, so the first listing 401s.
        installFullServer(
            host: host, movies: [plexMovie(ratingKey: "1", title: "Arrival")], shows: [], episodes: [],
            acceptedToken: "fresh-token"
        )
        PlexServerStubProtocol.install(host: accountHost, replies: [
            "/api/v2/users/signin": .init(status: 201, body: #"{"authToken": "fresh-token"}"#)
        ])

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlexServerStubProtocol.self]
        let client = try PlexClient(
            urlSession: URLSession(configuration: config),
            accountBaseURL: #require(URL(string: "http://\(accountHost)"))
        )
        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host, token: "revoked", username: "bilipp", password: "test")
        try await ContentSyncManager(modelContainer: container, plexClient: client).syncPlaylist(playlist)

        let context = ModelContext(container)
        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.plexAccessToken == "fresh-token")
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 1)
    }

    @Test func `a rejected token fails the sync without touching the catalog`() async throws {
        let host = uniqueHost()
        defer { PlexServerStubProtocol.remove(host: host) }
        PlexServerStubProtocol.install(host: host, replies: [
            "/library/sections": .init(status: 401, body: "")
        ])

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host, token: "stale")
        await #expect(throws: PlexError.self) {
            try await makeManager(container: container).syncPlaylist(playlist)
        }

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == 0)
        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.syncStatus == .error)
    }

    // MARK: Playback

    @Test func `a Plex movie plays through the token-free URL with a header`() throws {
        let playlist = Playlist(name: "Plex", plexURL: "http://plex.test:32400", accessToken: "tok")
        let movie = Movie(id: "p-plex-1", streamId: 1, name: "Arrival")
        movie.directURL = "http://plex.test:32400/library/parts/1/17/file.mp4"

        let media = try #require(PlayableMedia.from(movie: movie, playlist: playlist))
        #expect(media.url.absoluteString == "http://plex.test:32400/library/parts/1/17/file.mp4")
        #expect(media.httpHeaders?["X-Plex-Token"] == "tok")
    }

    @Test func `a token-free Plex playlist carries no playback header`() throws {
        let playlist = Playlist(name: "Plex", plexURL: "http://plex.test:32400", accessToken: nil)
        let movie = Movie(id: "p-plex-1", streamId: 1, name: "Arrival")
        movie.directURL = "http://plex.test:32400/library/parts/1/17/file.mp4"

        let media = try #require(PlayableMedia.from(movie: movie, playlist: playlist))
        #expect(media.httpHeaders == nil)
    }
}

//
//  JellyfinSyncTests.swift
//  LumeTests
//
//  End-to-end tests for the Jellyfin sync pipeline: a stubbed server (login,
//  views, item pages) is synced through the real ContentSyncManager into an
//  in-memory store.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

// MARK: - Stub server

/// Serves canned Jellyfin JSON per endpoint, routing item queries on their
/// `ParentId` + `IncludeItemTypes` query items.
///
/// Keyed by a per-test host so parallel suites can never collide. Registered
/// only on the session handed to `JellyfinClient`, never globally.
private final nonisolated class JellyfinServerStubProtocol: URLProtocol {
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
        let key = Self.route(url)
        let reply = Self.lock.withLock { Self.replies[host]?[key] }
        let resolved = reply ?? Reply(status: 404, body: "")
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: resolved.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(resolved.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `POST /Users/AuthenticateByName`, `GET /Users/{id}/Views`, or
    /// `GET …/Items?ParentId=…&IncludeItemTypes=…`.
    private static func route(_ url: URL) -> String {
        let path = url.path
        guard path.hasSuffix("/Items"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.queryItems
        else { return path }
        let parent = query.first { $0.name == "ParentId" }?.value ?? ""
        let types = query.first { $0.name == "IncludeItemTypes" }?.value ?? ""
        return "\(path)|\(parent)|\(types)"
    }
}

// MARK: - Fixtures

private func jellyfinMovie(id: String, name: String, tag: String = "tag1") -> String {
    """
    {"Id": "\(id)", "Name": "\(name)", "Type": "Movie", "CommunityRating": 7.5,
     "PremiereDate": "2007-07-07T22:00:00.0000000Z", "ProductionYear": 2007,
     "Overview": "Overview of \(name).", "Genres": ["Fantasy"],
     "RunTimeTicks": 82945066670, "Container": "mp4",
     "DateCreated": "2026-09-17T09:51:37.0000000Z",
     "ImageTags": {"Primary": "\(tag)"},
     "ProviderIds": {"Tmdb": "329865", "Imdb": "tt0371724"}}
    """
}

private func jellyfinSeries(id: String, name: String) -> String {
    """
    {"Id": "\(id)", "Name": "\(name)", "Type": "Series",
     "Overview": "Overview of \(name).", "Genres": ["Drama"],
     "PremiereDate": "2023-01-01T00:00:00.0000000Z",
     "ImageTags": {"Primary": "stag"},
     "ProviderIds": {"Tmdb": "12345"}}
    """
}

// Six fixture fields, one per episode identity axis — a struct would just move
// the same six into an initializer.
// swiftlint:disable:next function_parameter_count
private func jellyfinEpisode(id: String, name: String, seriesId: String, seriesName: String, season: Int, number: Int) -> String {
    """
    {"Id": "\(id)", "Name": "\(name)", "Type": "Episode",
     "SeriesId": "\(seriesId)", "SeriesName": "\(seriesName)",
     "ParentIndexNumber": \(season), "IndexNumber": \(number),
     "PremiereDate": "2023-01-0\(number)T00:00:00.0000000Z",
     "RunTimeTicks": 27000000000, "Container": "mkv",
     "ImageTags": {"Primary": "etag"}}
    """
}

private func jellyfinPage(_ items: [String], total: Int) -> JellyfinServerStubProtocol.Reply {
    JellyfinServerStubProtocol.Reply(status: 200, body: """
    {"Items": [\(items.joined(separator: ","))], "TotalRecordCount": \(total)}
    """)
}

// MARK: - Tests

struct JellyfinSyncTests {
    private func uniqueHost() -> String {
        "jellyfin-\(UUID().uuidString.prefix(8).lowercased()).test"
    }

    private func makeManager(container: ModelContainer) -> ContentSyncManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JellyfinServerStubProtocol.self]
        let client = JellyfinClient(urlSession: URLSession(configuration: config))
        return ContentSyncManager(modelContainer: container, jellyfinClient: client)
    }

    private func makePlaylist(container: ModelContainer, host: String) throws -> Playlist {
        let context = ModelContext(container)
        let playlist = Playlist(
            name: "Test Jellyfin", serverURL: "http://\(host):8096",
            username: "bilipp", password: "test"
        )
        playlist.sourceType = .jellyfin
        context.insert(playlist)
        try context.save()
        return playlist
    }

    private func installFullServer(host: String, movies: [String], series: [String], episodes: [String]) {
        JellyfinServerStubProtocol.install(host: host, replies: [
            "/Users/AuthenticateByName": .init(status: 200, body: """
            {"AccessToken": "sess", "User": {"Id": "user1"}}
            """),
            "/Users/user1/Views": .init(status: 200, body: """
            {"Items": [
              {"Id": "libMovies", "Name": "Movies", "CollectionType": "movies"},
              {"Id": "libShows", "Name": "TV Shows", "CollectionType": "tvshows"},
              {"Id": "libMusic", "Name": "Music", "CollectionType": "music"}
            ], "TotalRecordCount": 3}
            """),
            "/Users/user1/Items|libMovies|Movie": jellyfinPage(movies, total: movies.count),
            "/Users/user1/Items|libShows|Series": jellyfinPage(series, total: series.count),
            "/Users/user1/Items|libShows|Episode": jellyfinPage(episodes, total: episodes.count)
        ])
    }

    // MARK: Full sync

    @Test func `a full sync imports movies, series, episodes and categories`() async throws {
        let host = uniqueHost()
        defer { JellyfinServerStubProtocol.remove(host: host) }
        installFullServer(
            host: host,
            movies: [jellyfinMovie(id: "m1", name: "Arrival")],
            series: [jellyfinSeries(id: "s1", name: "Harbor Lights")],
            episodes: [
                jellyfinEpisode(id: "e1", name: "Pilot", seriesId: "s1", seriesName: "Harbor Lights", season: 1, number: 1),
                jellyfinEpisode(id: "e2", name: "Tide", seriesId: "s1", seriesName: "Harbor Lights", season: 1, number: 2)
            ]
        )

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        let playlistId = playlist.id
        try await makeManager(container: container).syncPlaylist(playlist)

        let context = ModelContext(container)

        // The session from the login handshake is stored for playback.
        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.jellyfinAccessToken == "sess")
        #expect(stored.jellyfinUserId == "user1")
        #expect(stored.syncStatus == .idle)
        #expect(stored.lastSyncDate != nil)

        let movies = try context.fetch(FetchDescriptor<Movie>())
        #expect(movies.count == 1)
        let movie = try #require(movies.first)
        #expect(movie.name == "Arrival")
        #expect(movie.id == "\(playlistId.uuidString)-jellyfin-m1")
        #expect(movie.categoryId == "\(playlistId.uuidString)-vod-libMovies")
        // Token-free stream URL; the image URL carries the session token.
        #expect(movie.directURL == "http://\(host):8096/Videos/m1/stream?Static=true")
        #expect(movie.streamIcon?.contains("/Items/m1/Images/Primary") == true)
        #expect(movie.streamIcon?.contains("api_key=sess") == true)
        #expect(movie.rating == 7.5)
        #expect(movie.plot == "Overview of Arrival.")
        #expect(movie.tmdb == "329865")
        #expect(movie.imdbId == "tt0371724")

        let series = try context.fetch(FetchDescriptor<Series>())
        #expect(series.count == 1)
        let show = try #require(series.first)
        #expect(show.name == "Harbor Lights")
        #expect(show.categoryId == "\(playlistId.uuidString)-series-libShows")
        #expect(show.episodes.count == 2)
        let numbers = show.episodes.map(\.episodeNum).sorted()
        #expect(numbers == [1, 2])
        let pilot = try #require(show.episodes.first { $0.episodeNum == 1 })
        #expect(pilot.title == "Pilot")
        #expect(pilot.seasonNum == 1)
        #expect(pilot.directSource == "http://\(host):8096/Videos/e1/stream?Static=true")

        // One category per imported library; the music library is skipped.
        let categories = try context.fetch(FetchDescriptor<Lume.Category>())
        #expect(Set(categories.map(\.name)) == ["Movies", "TV Shows"])
        #expect(categories.allSatisfy { $0.type != .live })
        #expect(try context.fetch(FetchDescriptor<LiveStream>()).isEmpty)
    }

    // MARK: Prune

    @Test func `a second sync prunes removed titles and stores the fresh session`() async throws {
        let host = uniqueHost()
        defer { JellyfinServerStubProtocol.remove(host: host) }
        installFullServer(
            host: host,
            movies: [
                jellyfinMovie(id: "m1", name: "Arrival"),
                jellyfinMovie(id: "m2", name: "Gone")
            ],
            series: [jellyfinSeries(id: "s1", name: "Harbor Lights")],
            episodes: [
                jellyfinEpisode(id: "e1", name: "Pilot", seriesId: "s1", seriesName: "Harbor Lights", season: 1, number: 1)
            ]
        )

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        let manager = makeManager(container: container)
        try await manager.syncPlaylist(playlist)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Movie>()) == 2)

        // Second sync: one movie gone, new session token.
        JellyfinServerStubProtocol.install(host: host, replies: [
            "/Users/AuthenticateByName": .init(status: 200, body: """
            {"AccessToken": "sess2", "User": {"Id": "user1"}}
            """),
            "/Users/user1/Views": .init(status: 200, body: """
            {"Items": [
              {"Id": "libMovies", "Name": "Movies", "CollectionType": "movies"},
              {"Id": "libShows", "Name": "TV Shows", "CollectionType": "tvshows"}
            ], "TotalRecordCount": 2}
            """),
            "/Users/user1/Items|libMovies|Movie": jellyfinPage([jellyfinMovie(id: "m1", name: "Arrival")], total: 1),
            "/Users/user1/Items|libShows|Series": jellyfinPage([jellyfinSeries(id: "s1", name: "Harbor Lights")], total: 1),
            "/Users/user1/Items|libShows|Episode": jellyfinPage(
                [jellyfinEpisode(id: "e1", name: "Pilot", seriesId: "s1", seriesName: "Harbor Lights", season: 1, number: 1)],
                total: 1
            )
        ])
        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)
        let movies = try context.fetch(FetchDescriptor<Movie>())
        #expect(movies.count == 1)
        #expect(movies.first?.name == "Arrival")
        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.jellyfinAccessToken == "sess2")
    }

    // MARK: Login failure

    @Test func `a rejected login fails the sync without touching the catalog`() async throws {
        let host = uniqueHost()
        defer { JellyfinServerStubProtocol.remove(host: host) }
        JellyfinServerStubProtocol.install(host: host, replies: [
            "/Users/AuthenticateByName": .init(status: 401, body: "")
        ])

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        await #expect(throws: JellyfinError.self) {
            try await makeManager(container: container).syncPlaylist(playlist)
        }

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == 0)
        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.syncStatus == .error)
    }
}

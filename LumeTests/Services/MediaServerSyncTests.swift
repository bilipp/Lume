//
//  MediaServerSyncTests.swift
//  LumeTests
//
//  End-to-end tests for the Jellyfin/Emby sync pipeline: a stubbed server
//  (login, views, item pages) is synced through the real ContentSyncManager
//  into an in-memory store. One pipeline serves both products, so the Emby
//  cases below assert only what the flavour actually changes.
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
private func jellyfinEpisode(id: String, name: String, seriesId: String, seriesName: String?, season: Int, number: Int) -> String {
    let seriesNameField = seriesName.map { "\"SeriesName\": \"\($0)\"," } ?? ""
    return """
    {"Id": "\(id)", "Name": "\(name)", "Type": "Episode",
     "SeriesId": "\(seriesId)", \(seriesNameField)
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

struct MediaServerSyncTests {
    private func uniqueHost() -> String {
        "jellyfin-\(UUID().uuidString.prefix(8).lowercased()).test"
    }

    private func makeManager(container: ModelContainer) -> ContentSyncManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JellyfinServerStubProtocol.self]
        let client = JellyfinClient(urlSession: URLSession(configuration: config))
        return ContentSyncManager(modelContainer: container, jellyfinClient: client)
    }

    private func makePlaylist(container: ModelContainer, host: String, flavor: MediaServerFlavor = .jellyfin) throws -> Playlist {
        let context = ModelContext(container)
        let playlist = Playlist(
            name: "Test \(flavor.displayName)", serverURL: "http://\(host):8096",
            username: "bilipp", password: "test"
        )
        playlist.sourceType = flavor.sourceType
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

    // MARK: Emby

    /// Emby runs the same pipeline, so the only thing worth asserting is what
    /// the flavour changes: the id infix every row carries.
    @Test func `an Emby sync imports the same catalog under its own id infix`() async throws {
        let host = uniqueHost()
        defer { JellyfinServerStubProtocol.remove(host: host) }
        installFullServer(
            host: host,
            movies: [jellyfinMovie(id: "m1", name: "Arrival")],
            series: [jellyfinSeries(id: "s1", name: "Harbor Lights")],
            episodes: [
                jellyfinEpisode(id: "e1", name: "Pilot", seriesId: "s1", seriesName: "Harbor Lights", season: 1, number: 1)
            ]
        )

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host, flavor: .emby)
        let playlistId = playlist.id
        try await makeManager(container: container).syncPlaylist(playlist)

        let context = ModelContext(container)
        let movie = try #require(try context.fetch(FetchDescriptor<Movie>()).first)
        #expect(movie.id == "\(playlistId.uuidString)-emby-m1")
        #expect(movie.name == "Arrival")
        #expect(movie.directURL == "http://\(host):8096/Videos/m1/stream?Static=true")

        let show = try #require(try context.fetch(FetchDescriptor<Series>()).first)
        #expect(show.id == "\(playlistId.uuidString)-emby-s1")
        #expect(show.episodes.map(\.id) == ["\(playlistId.uuidString)-emby-episode-e1"])

        // The session columns are shared with Jellyfin, so Emby fills them too.
        let stored = try #require(try context.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.jellyfinAccessToken == "sess")
        #expect(stored.jellyfinUserId == "user1")
    }

    /// A mixed-content library reports no `CollectionType`. Skipping it — the
    /// old behaviour — imported nothing at all from a server whose only
    /// library is one, which is the default on a fresh Emby install.
    @Test func `a library with no collection type is walked for both kinds`() async throws {
        let host = uniqueHost()
        defer { JellyfinServerStubProtocol.remove(host: host) }
        JellyfinServerStubProtocol.install(host: host, replies: [
            "/Users/AuthenticateByName": .init(status: 200, body: """
            {"AccessToken": "sess", "User": {"Id": "user1"}}
            """),
            "/Users/user1/Views": .init(status: 200, body: """
            {"Items": [
              {"Id": "libMixed", "Name": "Mixed content"},
              {"Id": "libMusic", "Name": "Music", "CollectionType": "music"}
            ], "TotalRecordCount": 2}
            """),
            "/Users/user1/Items|libMixed|Movie": jellyfinPage([jellyfinMovie(id: "m1", name: "Arrival")], total: 1),
            "/Users/user1/Items|libMixed|Series": jellyfinPage([jellyfinSeries(id: "s1", name: "Harbor Lights")], total: 1),
            "/Users/user1/Items|libMixed|Episode": jellyfinPage(
                [jellyfinEpisode(id: "e1", name: "Pilot", seriesId: "s1", seriesName: "Harbor Lights", season: 1, number: 1)],
                total: 1
            )
        ])

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host, flavor: .emby)
        try await makeManager(container: container).syncPlaylist(playlist)

        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<Movie>()).map(\.name) == ["Arrival"])
        #expect(try context.fetch(FetchDescriptor<Series>()).map(\.name) == ["Harbor Lights"])
        // One category per kind for the same library; the music one is skipped.
        let categories = try context.fetch(FetchDescriptor<Lume.Category>())
        #expect(categories.map(\.name) == ["Mixed content", "Mixed content"])
        #expect(Set(categories.map(\.type)) == [.vod, .series])
    }

    /// A mis-scanned library — every loose episode file given its own
    /// `SeriesId`, all reporting the same `SeriesName`, with only one of
    /// those ids backed by a real `Series` item. Keying purely on the id
    /// produced one single-episode show per file. Observed on a real Emby
    /// install.
    @Test func `episodes with dangling series ids collapse onto the named shell`() async throws {
        let host = uniqueHost()
        defer { JellyfinServerStubProtocol.remove(host: host) }
        let show = "Love is Blind: Germany"
        installFullServer(
            host: host,
            movies: [],
            // Only `s8` exists as a Series item…
            series: [jellyfinSeries(id: "s8", name: show)],
            // …but the episodes point at s6, s8 and s9.
            episodes: [
                jellyfinEpisode(id: "e1", name: "One", seriesId: "s6", seriesName: show, season: 2, number: 1),
                jellyfinEpisode(id: "e2", name: "Two", seriesId: "s8", seriesName: show, season: 2, number: 2),
                jellyfinEpisode(id: "e3", name: "Three", seriesId: "s9", seriesName: show, season: 2, number: 3)
            ]
        )

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host, flavor: .emby)
        let playlistId = playlist.id
        try await makeManager(container: container).syncPlaylist(playlist)

        let context = ModelContext(container)
        let series = try context.fetch(FetchDescriptor<Series>())
        #expect(series.count == 1)
        let show0 = try #require(series.first)
        // All three land on the real shell, not on their dangling ids.
        #expect(show0.id == "\(playlistId.uuidString)-emby-s8")
        #expect(show0.episodes.map(\.episodeNum).sorted() == [1, 2, 3])
    }

    /// The same collapse when *no* shell exists at all: the name itself keys
    /// one synthesized row rather than one row per dangling id.
    @Test func `orphan episodes sharing a series name land in one shell`() async throws {
        let host = uniqueHost()
        defer { JellyfinServerStubProtocol.remove(host: host) }
        installFullServer(
            host: host,
            movies: [],
            series: [],
            episodes: [
                jellyfinEpisode(id: "e1", name: "One", seriesId: "s6", seriesName: "Orphans", season: 1, number: 1),
                jellyfinEpisode(id: "e2", name: "Two", seriesId: "s7", seriesName: "Orphans", season: 1, number: 2)
            ]
        )

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host, flavor: .emby)
        try await makeManager(container: container).syncPlaylist(playlist)

        let context = ModelContext(container)
        let series = try context.fetch(FetchDescriptor<Series>())
        #expect(series.count == 1)
        #expect(series.first?.name == "Orphans")
        #expect(series.first?.episodes.count == 2)
    }

    /// When the mapping changes between syncs — a corrected scan, a merged
    /// show — an existing episode must move to the new shell. Left attached
    /// to the old one it cascades away when that shell is pruned, taking the
    /// viewer's progress with it.
    @Test func `an episode re-filed under another series moves instead of vanishing`() async throws {
        let host = uniqueHost()
        defer { JellyfinServerStubProtocol.remove(host: host) }
        // First sync: no SeriesName, so each dangling id keys its own shell.
        installFullServer(
            host: host, movies: [], series: [],
            episodes: [
                jellyfinEpisode(id: "e1", name: "One", seriesId: "s6", seriesName: nil, season: 1, number: 1),
                jellyfinEpisode(id: "e2", name: "Two", seriesId: "s7", seriesName: nil, season: 1, number: 2)
            ]
        )

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host, flavor: .emby)
        let manager = makeManager(container: container)
        try await manager.syncPlaylist(playlist)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Series>()) == 2)

        // Second sync: the server now names the show, collapsing both onto it.
        installFullServer(
            host: host, movies: [],
            series: [jellyfinSeries(id: "s6", name: "Reunited")],
            episodes: [
                jellyfinEpisode(id: "e1", name: "One", seriesId: "s6", seriesName: "Reunited", season: 1, number: 1),
                jellyfinEpisode(id: "e2", name: "Two", seriesId: "s7", seriesName: "Reunited", season: 1, number: 2)
            ]
        )
        try await manager.syncPlaylist(playlist)

        let context = ModelContext(container)
        let series = try context.fetch(FetchDescriptor<Series>())
        #expect(series.count == 1)
        // Both episodes survived the move; neither cascaded away with the
        // shell that was pruned.
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 2)
        #expect(series.first?.episodes.map(\.episodeNum).sorted() == [1, 2])
    }

    /// The infix is what keeps one flavour's prune sweep off the other's rows
    /// when both live under the same playlist prefix.
    @Test func `an Emby prune leaves Jellyfin rows under the same playlist alone`() async throws {
        let host = uniqueHost()
        defer { JellyfinServerStubProtocol.remove(host: host) }
        installFullServer(host: host, movies: [jellyfinMovie(id: "m1", name: "Arrival")], series: [], episodes: [])

        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host, flavor: .emby)
        let playlistId = playlist.id

        let seed = ModelContext(container)
        seed.insert(Movie(id: "\(playlistId.uuidString)-jellyfin-zz", streamId: 9, name: "Foreign"))
        try seed.save()

        try await makeManager(container: container).syncPlaylist(playlist)

        let names = try Set(ModelContext(container).fetch(FetchDescriptor<Movie>()).map(\.name))
        #expect(names == ["Arrival", "Foreign"])
    }
}

//
//  JellyfinClient.swift
//  Lume
//
//  Talks to a Jellyfin *or Emby* server's REST API: password login, library
//  views and recursive item queries. The two are wire-compatible (see
//  `MediaServerFlavor`), so one client serves both and only `probe` tells them
//  apart. Playback and artwork URLs are derived from the item ids the sync
//  stores — the catalog rows never carry the session token (see
//  `PlayableMedia`), it travels in `httpHeaders` instead.
//

import Foundation

/// The session `POST /Users/AuthenticateByName` hands back. Value type so it
/// can cross the sync actor's boundary safely.
nonisolated struct JellyfinSession: Hashable {
    let accessToken: String
    let userId: String
}

nonisolated enum JellyfinError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case unauthorized
    case notAMediaServer
    case serverError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "The server URL is invalid.")
        case let .networkError(error):
            String(localized: "Network error: \(error.localizedDescription)")
        case .unauthorized:
            String(localized: "The server rejected these credentials.")
        case .notAMediaServer:
            String(localized: "This URL does not point to a Jellyfin or Emby server. Enter the server's base address, e.g. http://192.168.1.10:8096.")
        case let .serverError(code):
            String(localized: "Server error (HTTP \(code)).")
        case .invalidResponse:
            String(localized: "The server returned a response Lume could not read.")
        }
    }

    /// Credential-free summary for diagnostic logs. Interpolated with
    /// `privacy: .public`, so it must never carry a URL, a token or a password.
    var logDescription: String {
        switch self {
        case .invalidURL:
            "invalid URL"
        case let .networkError(error):
            "network error (\((error as NSError).domain) \((error as NSError).code))"
        case .unauthorized:
            "HTTP 401 unauthorized"
        case .notAMediaServer:
            "not a Jellyfin or Emby server"
        case let .serverError(code):
            "HTTP \(code)"
        case .invalidResponse:
            "unreadable response"
        }
    }
}

/// One entry of `GET /Users/{userId}/Views`: a library such as Movies or TV
/// Shows. Only `movies` and `tvshows` libraries are imported; the rest (music,
/// photos, books, …) is skipped.
///
/// Lower-camel properties against PascalCase JSON keys: the server's casing
/// must not leak into Swift names (and `Type` would collide with `foo.Type`).
nonisolated struct JellyfinLibrary: Decodable, Hashable {
    let id: String
    let name: String
    /// `movies`, `tvshows`, `music`, … — absent on some virtual folders.
    let collectionType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
    }
}

/// One entry of `GET /Users/{userId}/Items`. Only the fields the catalog build
/// asks for are decoded; everything else the server sends is ignored.
nonisolated struct JellyfinItem: Decodable, Hashable {
    let id: String
    let name: String?
    /// `Movie`, `Series`, `Season` or `Episode`.
    let itemType: String?
    let seriesId: String?
    let seriesName: String?
    let seasonName: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let premiereDate: String?
    let productionYear: Int?
    let overview: String?
    let genres: [String]?
    let communityRating: Double?
    let officialRating: String?
    /// 100ns ticks; divide by 10_000_000 for seconds.
    let runTimeTicks: Int64?
    let container: String?
    let dateCreated: String?
    /// e.g. `{"Primary": "<tag>", "Backdrop": "<tag>"}`.
    let imageTags: [String: String]?
    let providerIds: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case itemType = "Type"
        case seriesId = "SeriesId"
        case seriesName = "SeriesName"
        case seasonName = "SeasonName"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case premiereDate = "PremiereDate"
        case productionYear = "ProductionYear"
        case overview = "Overview"
        case genres = "Genres"
        case communityRating = "CommunityRating"
        case officialRating = "OfficialRating"
        case runTimeTicks = "RunTimeTicks"
        case container = "Container"
        case dateCreated = "DateCreated"
        case imageTags = "ImageTags"
        case providerIds = "ProviderIds"
    }

    var primaryImageTag: String? {
        imageTags?["Primary"]
    }

    var durationSecs: Int? {
        guard let runTimeTicks, runTimeTicks > 0 else { return nil }
        return Int(runTimeTicks / 10_000_000)
    }
}

nonisolated struct JellyfinItemsResponse: Decodable {
    let items: [JellyfinItem]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

nonisolated struct JellyfinViewsResponse: Decodable {
    let items: [JellyfinLibrary]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

private nonisolated struct JellyfinAuthUser: Decodable {
    let id: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

/// `GET /System/Info/Public` on both products. Jellyfin names itself in
/// `ProductName`; Emby omits that key entirely and is recognized by the
/// server identity it does send.
private nonisolated struct JellyfinPublicInfo: Decodable {
    let productName: String?
    let id: String?
    let version: String?

    enum CodingKeys: String, CodingKey {
        case productName = "ProductName"
        case id = "Id"
        case version = "Version"
    }
}

private nonisolated struct JellyfinAuthResponse: Decodable {
    let accessToken: String
    let user: JellyfinAuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
    }
}

/// `Sendable` because the sync actor holds it: the only stored property is an
/// immutable `URLSession`.
final nonisolated class JellyfinClient: Sendable {
    let session: URLSession

    init(urlSession: URLSession? = nil) {
        session = urlSession ?? Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpAdditionalHeaders = ["User-Agent": lumeCatalogUserAgent]
        return URLSession(configuration: config)
    }

    // MARK: - Authentication

    /// Logs in with a username + password. The `Authorization` (not
    /// `X-Emby-Authorization`) header is what Jellyfin 10.12+ with legacy auth
    /// disabled accepts — the `X-Emby-*` form answers 400 there.
    func authenticate(server: URL, username: String, password: String) async throws -> JellyfinSession {
        let url = server.appendingPathComponent("Users/AuthenticateByName")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.clientAuthorization, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])

        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw JellyfinError.unauthorized
        case 404:
            throw JellyfinError.notAMediaServer
        default:
            throw JellyfinError.serverError(response.statusCode)
        }
        guard let auth = try? JSONDecoder().decode(JellyfinAuthResponse.self, from: data),
              !auth.accessToken.isEmpty, !auth.user.id.isEmpty
        else {
            throw JellyfinError.invalidResponse
        }
        return JellyfinSession(accessToken: auth.accessToken, userId: auth.user.id)
    }

    // MARK: - Libraries & items

    /// The unauthenticated probe for the add-playlist connection test, which
    /// doubles as the Jellyfin/Emby discriminator. Answers on both products
    /// without credentials and 404s anywhere else.
    func probe(server: URL) async throws -> MediaServerFlavor {
        let url = server.appendingPathComponent("System/Info/Public")
        let (data, response) = try await send(URLRequest(url: url))
        guard response.statusCode == 200 else {
            throw JellyfinError.serverError(response.statusCode)
        }
        guard let info = try? JSONDecoder().decode(JellyfinPublicInfo.self, from: data) else {
            throw JellyfinError.notAMediaServer
        }
        if info.productName == "Jellyfin Server" {
            return .jellyfin
        }
        // Emby sends no `ProductName`. Requiring both an id and a version
        // keeps an unrelated JSON endpoint that happens to answer 200 here
        // from being taken for a media server.
        guard info.id?.isEmpty == false, info.version?.isEmpty == false else {
            throw JellyfinError.notAMediaServer
        }
        return .emby
    }

    func views(server: URL, session: JellyfinSession) async throws -> [JellyfinLibrary] {
        let url = server
            .appendingPathComponent("Users/\(session.userId)/Views")
        let response: JellyfinViewsResponse = try await get(url, session: session)
        return response.items
    }

    /// One page of a recursive item query. The caller pages with `startIndex`
    /// until it has `TotalRecordCount` rows.
    func items(
        server: URL,
        session: JellyfinSession,
        parentId: String? = nil,
        types: [String],
        startIndex: Int = 0,
        limit: Int = 200
    ) async throws -> JellyfinItemsResponse {
        var components = URLComponents(
            url: server.appendingPathComponent("Users/\(session.userId)/Items"),
            resolvingAgainstBaseURL: false
        ) ?? URLComponents()
        var query: [URLQueryItem] = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: types.joined(separator: ",")),
            URLQueryItem(name: "Fields", value: Self.itemFields),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        if let parentId {
            query.append(URLQueryItem(name: "ParentId", value: parentId))
        }
        components.queryItems = query
        guard let url = components.url else { throw JellyfinError.invalidURL }
        return try await get(url, session: session)
    }

    // MARK: - URL builders

    /// Direct-play stream URL, deliberately token-free: the session token
    /// travels in `httpHeaders` (see `PlayableMedia`), so a persisted or
    /// shared URL never carries a credential.
    nonisolated static func streamURL(server: URL, itemId: String) -> URL? {
        var components = URLComponents(url: server.appendingPathComponent("Videos/\(itemId)/stream"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "Static", value: "true")]
        return components?.url
    }

    /// Artwork URL. Unlike streams this one embeds the token: image loaders
    /// fetch a plain URL with no chance to attach headers. Refreshed on every
    /// sync alongside the token itself.
    nonisolated static func imageURL(server: URL, itemId: String, tag: String, kind: String = "Primary", maxWidth: Int = 600, token: String) -> URL? {
        var components = URLComponents(url: server.appendingPathComponent("Items/\(itemId)/Images/\(kind)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "api_key", value: token)
        ]
        return components?.url
    }

    /// The request authorization for an authenticated call.
    nonisolated static func authorization(token: String) -> String {
        "\(clientAuthorization), Token=\"\(token)\""
    }

    /// The playback header a `PlayableMedia` carries for its stream. `nil`
    /// when the playlist holds no session yet (before its first sync) — the
    /// engines then try the bare URL, which the server answers with a 401.
    nonisolated static func playbackHeaders(token: String?) -> [String: String]? {
        guard let token, !token.isEmpty else { return nil }
        return ["Authorization": authorization(token: token)]
    }

    // MARK: - Request plumbing

    private func get<T: Decodable>(_ url: URL, session: JellyfinSession) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(Self.authorization(token: session.accessToken), forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw JellyfinError.unauthorized
        default:
            throw JellyfinError.serverError(response.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw JellyfinError.invalidResponse
        }
        return decoded
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JellyfinError.networkError(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }
        return (data, httpResponse)
    }

    /// Strips a trailing slash so `appendingPathComponent` never builds a
    /// double-slash path (which Jellyfin answers with a redirect that drops
    /// the POST body).
    nonisolated static func normalizedServerURL(_ url: URL) -> URL {
        let string = url.absoluteString
        guard string.hasSuffix("/"), string.count > 1 else { return url }
        return URL(string: String(string.dropLast())) ?? url
    }

    /// Only the item fields the catalog build reads. The server's default
    /// field set omits `ImageTags` and `ProviderIds`, which are what posters
    /// and TMDB matching are built from.
    private static let itemFields = [
        "Path", "ProviderIds", "PremiereDate", "ProductionYear", "Overview",
        "Genres", "OfficialRating", "CommunityRating", "RunTimeTicks",
        "Container", "ImageTags", "SeriesName", "SeriesId", "SeasonName",
        "SeasonId", "IndexNumber", "ParentIndexNumber", "DateCreated"
    ].joined(separator: ",")

    /// `MediaBrowser Client="Lume", Device="…", DeviceId="…", Version="…"` —
    /// the form Jellyfin 10.12+ requires on `Authorization`. The device id is
    /// stable per install so the server's device list doesn't grow a row per
    /// login.
    private static var clientAuthorization: String {
        // Informational only — the server shows it in its device/session list.
        let device = ProcessInfo.processInfo.hostName
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "MediaBrowser Client=\"Lume\", Device=\"\(device)\", DeviceId=\"\(deviceId)\", Version=\"\(version)\""
    }

    private static var deviceId: String {
        let key = "jellyfin.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}

// MARK: - Playback auth for the header-less engine

/// VLCKit exposes no arbitrary-header API, so the Jellyfin/Emby session token a
/// `PlayableMedia` carries as `Authorization: MediaBrowser Token="…"` is
/// converted back into a transient `api_key` query item at the handoff — the
/// same contract as `HTTPBasicCredentials`: built at the point of use, never
/// persisted onto a catalog row, a deep link or restoration state.
nonisolated enum JellyfinPlaybackAuth {
    /// The session token inside a playback header value, if it is a Jellyfin
    /// `MediaBrowser … Token="…"` header rather than a Basic one.
    static func token(from headers: [String: String]?) -> String? {
        guard let value = headers?["Authorization"],
              value.hasPrefix("MediaBrowser"),
              let range = value.range(of: "Token=\"")
        else { return nil }
        let rest = value[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let token = String(rest[..<end])
        return token.isEmpty ? nil : token
    }

    static func authenticatedURL(_ url: URL, headers: [String: String]?) -> URL? {
        guard let token = token(from: headers),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "api_key" }) else { return url }
        items.append(URLQueryItem(name: "api_key", value: token))
        components.queryItems = items
        return components.url
    }
}

//
//  PlexClient.swift
//  Lume
//
//  Talks to a Plex Media Server: token resolution, library sections and the
//  paged item queries behind them. Unlike Jellyfin/Emby, Plex wraps every
//  response in a `MediaContainer` and authenticates with a single
//  `X-Plex-Token` rather than a per-user session.
//
//  A token can come from three places, tried in that order by
//  `PlexAddCheck`: a plex.tv sign-in, a token pasted by the user, or none at
//  all — a server with "allow unauthenticated access on the local network"
//  answers every request without one.
//

import Foundation

nonisolated enum PlexError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case unauthorized
    case notAPlexServer
    case serverError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "The server URL is invalid.")
        case let .networkError(error):
            String(localized: "Network error: \(error.localizedDescription)")
        case .unauthorized:
            String(localized: "The Plex server rejected this token.")
        case .notAPlexServer:
            String(localized: "This URL does not point to a Plex server. Enter the server's base address, e.g. http://192.168.1.10:32400.")
        case let .serverError(code):
            String(localized: "Server error (HTTP \(code)).")
        case .invalidResponse:
            String(localized: "The server returned a response Lume could not read.")
        }
    }

    /// Credential-free summary for diagnostic logs. Interpolated with
    /// `privacy: .public`, so it must never carry a URL or a token.
    var logDescription: String {
        switch self {
        case .invalidURL:
            "invalid URL"
        case let .networkError(error):
            "network error (\((error as NSError).domain) \((error as NSError).code))"
        case .unauthorized:
            "HTTP 401 unauthorized"
        case .notAPlexServer:
            "not a Plex server"
        case let .serverError(code):
            "HTTP \(code)"
        case .invalidResponse:
            "unreadable response"
        }
    }
}

// MARK: - DTOs

/// One entry of `GET /library/sections`: a library such as Movies or TV Shows.
/// Only `movie` and `show` sections are imported; the rest (music, photo, …)
/// is skipped.
nonisolated struct PlexSection: Decodable, Hashable {
    /// The section key used in `/library/sections/{key}/all`. A number in
    /// practice, but the API types it as a string.
    let key: String
    let title: String
    /// `movie`, `show`, `artist`, `photo`.
    let type: String?
}

/// One `Metadata` entry of a library query. Plex reuses the same shape for
/// movies, shows and episodes, so one type decodes all three; which fields
/// are populated depends on `type`.
nonisolated struct PlexMetadata: Decodable, Hashable {
    /// The item's stable server-local id. Numeric in practice.
    let ratingKey: String
    let type: String?
    let title: String?
    let summary: String?
    let year: Int?
    /// Critic rating on a 0–10 scale.
    let rating: Double?
    let audienceRating: Double?
    let contentRating: String?
    /// Milliseconds.
    let duration: Int?
    let originallyAvailableAt: String?
    /// Poster path, relative to the server root.
    let thumb: String?
    let art: String?
    /// Unix seconds.
    let addedAt: Int?
    /// Episodes only: the show and season they belong to.
    let grandparentRatingKey: String?
    let grandparentTitle: String?
    let grandparentThumb: String?
    let parentIndex: Int?
    let index: Int?
    let media: [PlexMedia]?
    let genre: [PlexTag]?
    /// `[{"id": "tmdb://675"}, {"id": "imdb://tt0373889"}]` — only present
    /// with `includeGuids=1`.
    let guids: [PlexGuid]?

    enum CodingKeys: String, CodingKey {
        case ratingKey, type, title, summary, year, rating, audienceRating
        case contentRating, duration, originallyAvailableAt, thumb, art, addedAt
        case grandparentRatingKey, grandparentTitle, grandparentThumb
        case parentIndex, index
        case media = "Media"
        case genre = "Genre"
        case guids = "Guid"
    }

    var durationSecs: Int? {
        guard let duration, duration > 0 else { return nil }
        return duration / 1000
    }

    /// The path of the first playable part, relative to the server root. Plex
    /// serves the file itself at this path, so it is what direct play opens.
    var partKey: String? {
        media?.compactMap { $0.part?.first?.key }.first
    }

    var container: String? {
        media?.first?.container ?? media?.first?.part?.first?.container
    }

    var genreList: String? {
        guard let tags = genre?.compactMap(\.tag), !tags.isEmpty else { return nil }
        return tags.joined(separator: ", ")
    }

    /// The bare id behind a `<service>://<id>` guid, e.g. `tmdb://675`.
    func providerId(_ service: String) -> String? {
        let prefix = "\(service)://"
        return guids?.compactMap(\.id).first { $0.hasPrefix(prefix) }?.dropFirst(prefix.count).description
    }
}

nonisolated struct PlexMedia: Decodable, Hashable {
    let container: String?
    let part: [PlexPart]?

    enum CodingKeys: String, CodingKey {
        case container
        case part = "Part"
    }
}

nonisolated struct PlexPart: Decodable, Hashable {
    let key: String?
    let container: String?
}

nonisolated struct PlexTag: Decodable, Hashable {
    let tag: String?
}

nonisolated struct PlexGuid: Decodable, Hashable {
    let id: String?
}

/// The body of every Plex response. `totalSize` appears only on a paged
/// query; `size` is the number of rows in this page. Rows arrive under
/// `Directory` for section listings and `Metadata` for item listings.
private nonisolated struct PlexMediaContainer<Row: Decodable>: Decodable {
    let size: Int?
    let totalSize: Int?
    let machineIdentifier: String?
    let directory: [Row]?
    let metadata: [Row]?

    enum CodingKeys: String, CodingKey {
        case size, totalSize, machineIdentifier
        case directory = "Directory"
        case metadata = "Metadata"
    }
}

/// Every Plex response is wrapped in a `MediaContainer`.
private nonisolated struct PlexContainerResponse<Row: Decodable>: Decodable {
    let container: PlexMediaContainer<Row>

    enum CodingKeys: String, CodingKey {
        case container = "MediaContainer"
    }
}

/// One page of a library query.
nonisolated struct PlexPage: Hashable {
    let items: [PlexMetadata]
    /// The server's count for the whole query. Plex omits `totalSize` when a
    /// query fits in one page, in which case this is the page's own size.
    let totalSize: Int
}

/// The plex.tv sign-in response. Only the token is read.
private nonisolated struct PlexSignInResponse: Decodable {
    let authToken: String?
}

// MARK: - Client

/// `Sendable` because the sync actor holds it: the only stored property is an
/// immutable `URLSession`.
final nonisolated class PlexClient: Sendable {
    let session: URLSession
    /// Overridable so tests can point the sign-in at a stub instead of the
    /// real plex.tv. Production callers leave it at the default.
    let accountBaseURL: URL

    /// Plex's item `type` query values.
    static let movieType = 1
    static let showType = 2
    static let episodeType = 4

    /// Rows per page. Plex happily serves more, but a large page on a slow
    /// LAN link is what makes a sync look hung.
    static let pageSize = 200

    init(urlSession: URLSession? = nil, accountBaseURL: URL? = nil) {
        session = urlSession ?? Self.makeSession()
        self.accountBaseURL = accountBaseURL ?? URL(string: "https://plex.tv")!
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpAdditionalHeaders = ["User-Agent": lumeCatalogUserAgent]
        return URLSession(configuration: config)
    }

    // MARK: - Authentication

    /// Exchanges a plex.tv account login for a server token. Accounts with
    /// two-factor enabled append the current code to the password, which is
    /// what Plex's own clients do — no separate field is needed.
    func signIn(username: String, password: String) async throws -> String {
        var request = URLRequest(url: accountBaseURL.appendingPathComponent("api/v2/users/signin"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in Self.clientIdentityHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONEncoder().encode(["login": username, "password": password])

        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200, 201:
            break
        case 400, 401, 403:
            throw PlexError.unauthorized
        default:
            throw PlexError.serverError(response.statusCode)
        }
        guard let token = try? JSONDecoder().decode(PlexSignInResponse.self, from: data).authToken,
              !token.isEmpty
        else {
            throw PlexError.invalidResponse
        }
        return token
    }

    /// The unauthenticated probe for the add-playlist connection test.
    /// `/identity` answers on every Plex server without a token and 404s
    /// anywhere else.
    func probe(server: URL) async throws {
        let url = server.appendingPathComponent("identity")
        let (data, response) = try await send(jsonRequest(url, token: nil))
        guard response.statusCode == 200 else {
            throw PlexError.serverError(response.statusCode)
        }
        guard let identity = try? JSONDecoder().decode(PlexContainerResponse<PlexSection>.self, from: data),
              identity.container.machineIdentifier?.isEmpty == false
        else {
            throw PlexError.notAPlexServer
        }
    }

    /// Verifies a token by asking for something `/identity` does not gate.
    /// A server that allows unauthenticated local access answers this without
    /// one, which is exactly how a token-less playlist is validated.
    func sections(server: URL, token: String?) async throws -> [PlexSection] {
        let url = server.appendingPathComponent("library/sections")
        let container: PlexContainerResponse<PlexSection> = try await get(url, token: token)
        return container.container.directory ?? []
    }

    /// One page of a library query. The caller pages with `start` until it has
    /// `totalSize` rows.
    func items(
        server: URL,
        token: String?,
        sectionKey: String,
        type: Int,
        start: Int = 0,
        limit: Int = PlexClient.pageSize
    ) async throws -> PlexPage {
        var components = URLComponents(
            url: server.appendingPathComponent("library/sections/\(sectionKey)/all"),
            resolvingAgainstBaseURL: false
        ) ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "type", value: String(type)),
            URLQueryItem(name: "includeGuids", value: "1"),
            URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(limit))
        ]
        guard let url = components.url else { throw PlexError.invalidURL }
        let container: PlexContainerResponse<PlexMetadata> = try await get(url, token: token)
        let items = container.container.metadata ?? []
        return PlexPage(items: items, totalSize: container.container.totalSize ?? items.count)
    }

    // MARK: - URL builders

    /// Direct-play stream URL, deliberately token-free: the token travels in
    /// `httpHeaders` (see `PlayableMedia`), so a persisted or shared URL never
    /// carries a credential.
    nonisolated static func streamURL(server: URL, partKey: String) -> URL? {
        URL(string: partKey, relativeTo: server)?.absoluteURL
    }

    /// Artwork URL. Unlike streams this one embeds the token: image loaders
    /// fetch a plain URL with no chance to attach headers. Refreshed on every
    /// sync alongside the token itself.
    nonisolated static func imageURL(server: URL, path: String, token: String?) -> URL? {
        guard var components = URLComponents(
            url: URL(string: path, relativeTo: server)?.absoluteURL ?? server,
            resolvingAgainstBaseURL: false
        ) else { return nil }
        if let token, !token.isEmpty {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: tokenQueryItem, value: token))
            components.queryItems = items
        }
        return components.url
    }

    /// The playback header a `PlayableMedia` carries for its stream. `nil`
    /// when the playlist holds no token — either the server allows
    /// unauthenticated access, or the playlist has not synced yet.
    nonisolated static func playbackHeaders(token: String?) -> [String: String]? {
        guard let token, !token.isEmpty else { return nil }
        return [tokenHeader: token]
    }

    nonisolated static let tokenHeader = "X-Plex-Token"
    nonisolated static let tokenQueryItem = "X-Plex-Token"

    /// Strips a trailing slash so `appendingPathComponent` never builds a
    /// double-slash path.
    nonisolated static func normalizedServerURL(_ url: URL) -> URL {
        let string = url.absoluteString
        guard string.hasSuffix("/"), string.count > 1 else { return url }
        return URL(string: String(string.dropLast())) ?? url
    }

    // MARK: - Request plumbing

    private func get<T: Decodable>(_ url: URL, token: String?) async throws -> T {
        let (data, response) = try await send(jsonRequest(url, token: token))
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw PlexError.unauthorized
        default:
            throw PlexError.serverError(response.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw PlexError.invalidResponse
        }
        return decoded
    }

    /// Plex serves XML by default and only switches to JSON on
    /// `Accept: application/json`, so every request has to ask for it.
    private func jsonRequest(_ url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in Self.clientIdentityHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: Self.tokenHeader)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PlexError.networkError(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.invalidResponse
        }
        return (data, httpResponse)
    }

    /// The `X-Plex-*` identity every request carries. The client identifier is
    /// stable per install so the server's device list doesn't grow a row per
    /// launch, and plex.tv ties the issued token to it.
    private static var clientIdentityHeaders: [String: String] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return [
            "X-Plex-Product": "Lume",
            "X-Plex-Version": version,
            "X-Plex-Client-Identifier": clientIdentifier,
            // Informational only — the server shows it in its device list.
            "X-Plex-Device": ProcessInfo.processInfo.hostName,
            "X-Plex-Platform": platformName
        ]
    }

    private static var platformName: String {
        #if os(tvOS)
            "tvOS"
        #elseif os(macOS)
            "macOS"
        #elseif os(visionOS)
            "visionOS"
        #else
            "iOS"
        #endif
    }

    private static var clientIdentifier: String {
        let key = "plex.clientIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}

// MARK: - Playback auth for the header-less engine

/// VLCKit exposes no arbitrary-header API, so the Plex token a `PlayableMedia`
/// carries as `X-Plex-Token` is converted back into a transient query item at
/// the handoff — the same contract as `HTTPBasicCredentials` and
/// `JellyfinPlaybackAuth`: built at the point of use, never persisted onto a
/// catalog row, a deep link or restoration state.
nonisolated enum PlexPlaybackAuth {
    static func token(from headers: [String: String]?) -> String? {
        guard let value = headers?[PlexClient.tokenHeader], !value.isEmpty else { return nil }
        return value
    }

    static func authenticatedURL(_ url: URL, headers: [String: String]?) -> URL? {
        guard let token = token(from: headers),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == PlexClient.tokenQueryItem }) else { return url }
        items.append(URLQueryItem(name: PlexClient.tokenQueryItem, value: token))
        components.queryItems = items
        return components.url
    }
}

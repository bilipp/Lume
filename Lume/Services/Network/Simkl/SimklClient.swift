//
//  SimklClient.swift
//  Lume
//
//  Stateless networking client for the Simkl API, covering the OAuth 2.0
//  *device* flow (RFC 8628 — the only flow that works on tvOS, and uniform
//  across every platform), token refresh/revoke, the connected user's profile,
//  watched-history sync, and the full watchlist pull used by the import.
//
//  Simkl's AUTH V2 requires no client secret for TV/device registrations, so
//  the secret is optional and only sent when present. Every request carries
//  `client_id`, `app-name` and `app-version` as query parameters plus a
//  `User-Agent` header, as Simkl's headers convention requires.
//
//  The client id/secret live in the git-ignored `.env` file and are injected
//  into Info.plist at build time by Scripts/inject-env.sh — never committed.
//

import Foundation

// MARK: - Errors

enum SimklError: Error, Equatable {
    case notConfigured
    case invalidResponse
    case server(Int)
    case decoding
    case notAuthenticated

    // Device-flow polling outcomes (Simkl AUTH V2, RFC 8628). There is no
    // "denied" signal: declining writes nothing, so the code simply keeps
    // polling until it expires — the deadline in `SimklService` is the only
    // way a declined code ever ends.
    case authorizationPending
    case slowDown
    case codeExpired
    case invalidClient
}

// MARK: - Client

/// Read/write Simkl client. Stateless: the caller supplies the access token for
/// authenticated endpoints, so token lifecycle lives in `SimklService`.
nonisolated struct SimklClient {
    static let shared = SimklClient()

    private let baseURL = "https://api.simkl.com"

    /// Scope requested with the device flow. `media:read` alone can't scrobble,
    /// so both are asked for explicitly — an unrecognized scope string is
    /// silently downgraded to read-only rather than rejected, and the response's
    /// `scope` is what the token actually got.
    private static let scope = "media:read media:write"

    private let session: URLSession
    private let clientID: String?
    private let clientSecret: String?

    init(
        session: URLSession = .shared,
        clientID: String? = SimklClient.value(for: "SimklClientID"),
        clientSecret: String? = SimklClient.value(for: "SimklClientSecret")
    ) {
        self.session = session
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Whether usable credentials are present. Simkl only ever needs the client
    /// id (TV/device registrations have no secret); a secret present for a
    /// server-app registration is sent along when there. When false the whole
    /// integration is hidden rather than surfacing errors.
    var isConfigured: Bool {
        guard let clientID, !clientID.isEmpty, !clientID.hasPrefix("$(") else { return false }
        return true
    }

    private static func value(for key: String) -> String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var appVersion: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
    }

    private static var userAgent: String {
        "Lume/\(appVersion)"
    }

    /// The URL the user opens to approve the device code — the pre-filled
    /// variant when the server returned one, else the plain PIN page.
    static func activationURL(for code: SimklDeviceCode) -> URL? {
        if let complete = code.verificationURLComplete, let url = URL(string: complete) {
            return url
        }
        return URL(string: code.verificationURL)
    }

    // MARK: - OAuth: device flow

    /// Requests a device + user code to begin authorization. The user approves
    /// at `verificationURL`, which the `verificationURLComplete` variant carries
    /// pre-filled — the one a QR code should point at.
    func requestDeviceCode() async throws -> SimklDeviceCode {
        guard let clientID, isConfigured else { throw SimklError.notConfigured }
        let body = ["client_id": clientID, "scope": Self.scope]
        return try await postOAuth("/oauth2/device", body: body)
    }

    /// Polls once for the token. Maps Simkl's documented polling outcomes to
    /// typed errors so `SimklService` can drive the loop.
    func pollForToken(deviceCode: String) async throws -> SimklTokenResponse {
        guard let clientID, isConfigured else { throw SimklError.notConfigured }
        let body: [String: String] = [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": clientID,
            "device_code": deviceCode
        ]
        return try await postOAuth("/oauth2/token", body: body)
    }

    /// Exchanges a refresh token for a fresh token set. Simkl's refresh token
    /// is non-rotating: the same string comes back with its 180-day window slid
    /// forward, and the previous access token dies immediately.
    func refreshToken(_ refreshToken: String) async throws -> SimklTokenResponse {
        guard let clientID, isConfigured else { throw SimklError.notConfigured }
        var body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken
        ]
        if let clientSecret, !clientSecret.isEmpty, !clientSecret.hasPrefix("$(") {
            body["client_secret"] = clientSecret
        }
        return try await postOAuth("/oauth2/token", body: body)
    }

    /// Revokes the token server-side. Best-effort: failures are ignored by the
    /// caller since the local token is cleared regardless. Always answers 200,
    /// even for a token that never existed.
    func revokeToken(_ accessToken: String) async throws {
        guard isConfigured else { throw SimklError.notConfigured }
        var body: [String: String] = ["token": accessToken]
        if let clientSecret, !clientSecret.isEmpty, !clientSecret.hasPrefix("$(") {
            body["client_secret"] = clientSecret
        }
        let _: EmptyResponse = try await postOAuth("/oauth2/revoke", body: body)
    }

    // MARK: - User

    /// The connected user's profile (used to show "Connected as …").
    func currentUser(accessToken: String) async throws -> SimklUser {
        let settings: SimklUserSettings = try await get("/users/settings", accessToken: accessToken)
        return settings.user
    }

    // MARK: - Watched history (sync)

    /// Adds movies/episodes to the user's watched history.
    func addToHistory(_ items: SimklSyncItems, accessToken: String) async throws {
        let _: SimklSyncResponse = try await post("/sync/history", body: items, accessToken: accessToken)
    }

    /// Removes movies/episodes from the user's watched history.
    func removeFromHistory(_ items: SimklSyncItems, accessToken: String) async throws {
        let _: SimklSyncResponse = try await post("/sync/history/remove", body: items, accessToken: accessToken)
    }

    // MARK: - Watched history (import)

    /// The user's whole library — every list, with the watched episodes nested
    /// and per-episode timestamps — in a single unpaginated response. Movies
    /// are watched when their status is `completed` (movies have no "watching"
    /// state); shows carry the watched seasons/episodes to mark.
    func watchedItems(accessToken: String) async throws -> SimklAllItems {
        let request = try makeRequest(
            path: "/sync/all-items/",
            method: "GET",
            query: [
                URLQueryItem(name: "extended", value: "full"),
                URLQueryItem(name: "episode_watched_at", value: "yes")
            ],
            accessToken: accessToken
        )
        let (data, _) = try await send(request)
        // An account with nothing in any list answers `null`, which no Decodable
        // type can decode — read it as an empty library instead.
        let trimmed = data.trimmingJSONWhitespace()
        guard trimmed != "null", !trimmed.isEmpty else { return SimklAllItems.empty }
        do {
            return try JSONDecoder().decode(SimklAllItems.self, from: data)
        } catch {
            throw SimklError.decoding
        }
    }

    // MARK: - Networking

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], accessToken: String) async throws -> T {
        let request = try makeRequest(path: path, method: "GET", query: query, accessToken: accessToken)
        let (data, response) = try await send(request)
        try Self.requireSuccess(response)
        return try Self.decode(data)
    }

    /// POSTs a sync payload. Content-Type is JSON; sync endpoints answer 200 or
    /// 201 (both accepted by `send`).
    private func post<T: Decodable>(
        _ path: String,
        body: some Encodable,
        accessToken: String
    ) async throws -> T {
        let request = try makeRequest(path: path, method: "POST", accessToken: accessToken)
        let payload = try JSONEncoder().encode(body)
        let (data, response) = try await send(request, body: payload)
        try Self.requireSuccess(response)
        return try Self.decode(data)
    }

    private static func requireSuccess(_ response: HTTPURLResponse) throws {
        guard (200 ... 299).contains(response.statusCode) else {
            if response.statusCode == 401 {
                throw SimklError.notAuthenticated
            }
            throw SimklError.server(response.statusCode)
        }
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SimklError.decoding
        }
    }

    /// POSTs an OAuth endpoint. These report failures through an RFC 6749 §5.2
    /// error envelope (`{"error": "authorization_pending", …}`) at 400/401
    /// rather than plain status codes, so the body is decoded on failure and
    /// mapped to typed errors.
    private func postOAuth<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        let request = try makeRequest(path: path, method: "POST", accessToken: nil)
        let (data, response) = try await send(request, body: JSONEncoder().encode(body))
        guard (200 ... 299).contains(response.statusCode) else {
            if let envelope = try? JSONDecoder().decode(SimklOAuthError.self, from: data) {
                switch (response.statusCode, envelope.error) {
                case (401, _):
                    throw SimklError.invalidClient
                case (_, "authorization_pending"):
                    throw SimklError.authorizationPending
                case (_, "slow_down"):
                    throw SimklError.slowDown
                case (_, "expired_token"):
                    throw SimklError.codeExpired
                default:
                    throw SimklError.server(response.statusCode)
                }
            }
            throw SimklError.server(response.statusCode)
        }
        return try Self.decode(data)
    }

    private func makeRequest(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        accessToken: String?
    ) throws -> URLRequest {
        guard let clientID, var components = URLComponents(string: baseURL + path) else {
            throw SimklError.notConfigured
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "app-name", value: "lume"),
            URLQueryItem(name: "app-version", value: Self.appVersion)
        ] + query
        guard let url = components.url else { throw SimklError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Transport only: performs the request and returns the raw body and
    /// response whatever the status — OAuth endpoints carry their failures in
    /// the body, so status handling lives with each call site.
    private func send(_ request: URLRequest, body: Data? = nil) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = request
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SimklError.invalidResponse }
        return (data, http)
    }
}

// MARK: - DTOs

/// Decoded `/oauth2/device` response.
nonisolated struct SimklDeviceCode: Decodable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    /// `verification_uri` with the code pre-filled — the QR-code target.
    let verificationURLComplete: String?
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURL = "verification_uri"
        case verificationURLComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

/// Decoded `/oauth2/token` response, shared by the device and refresh grants.
nonisolated struct SimklTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    /// Access tokens live 7 days (`expires_in: 604800`).
    let expiresIn: TimeInterval
    let scope: String?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }

    var tokens: SimklTokens {
        SimklTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            issuedAt: Date().timeIntervalSince1970,
            expiresIn: expiresIn,
            scope: scope,
            tokenType: tokenType
        )
    }
}

/// RFC 6749 §5.2 error envelope for the `/oauth2/*` endpoints.
private nonisolated struct SimklOAuthError: Decodable {
    let error: String
}

nonisolated struct SimklUserSettings: Decodable {
    let user: SimklUser
}

nonisolated struct SimklUser: Decodable {
    let name: String
}

// MARK: - Sync payloads

/// External-id bag accepted by Simkl sync endpoints. We only ever have a TMDB
/// id from the library, which Simkl resolves on its end. TMDB ids arrive as
/// integers or strings depending on the entry, and are accepted either way on
/// write.
nonisolated struct SimklIDs: Encodable {
    var tmdb: Int?
}

nonisolated struct SimklMoviePayload: Encodable {
    let title: String?
    let ids: SimklIDs
}

nonisolated struct SimklEpisodeNumber: Encodable {
    let number: Int
}

nonisolated struct SimklSeasonPayload: Encodable {
    let number: Int
    let episodes: [SimklEpisodeNumber]
}

nonisolated struct SimklShowPayload: Encodable {
    let title: String?
    let ids: SimklIDs
    let seasons: [SimklSeasonPayload]
}

/// Body for `/sync/history` (add and remove). Only the populated arrays are
/// encoded.
nonisolated struct SimklSyncItems: Encodable {
    var movies: [SimklMoviePayload] = []
    var shows: [SimklShowPayload] = []

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !movies.isEmpty {
            try container.encode(movies, forKey: .movies)
        }
        if !shows.isEmpty {
            try container.encode(shows, forKey: .shows)
        }
    }

    enum CodingKeys: String, CodingKey {
        case movies, shows
    }

    static func movie(tmdbID: Int, title: String?) -> SimklSyncItems {
        SimklSyncItems(movies: [SimklMoviePayload(title: title, ids: SimklIDs(tmdb: tmdbID))])
    }

    static func episode(showTMDBID: Int, showTitle: String?, season: Int, episode: Int) -> SimklSyncItems {
        SimklSyncItems(shows: [
            SimklShowPayload(
                title: showTitle,
                ids: SimklIDs(tmdb: showTMDBID),
                seasons: [SimklSeasonPayload(number: season, episodes: [SimklEpisodeNumber(number: episode)])]
            )
        ])
    }
}

private nonisolated struct SimklSyncResponse: Decodable {} // We don't act on the add/remove summary.

// MARK: - Watched history (import)

/// Decoded `/sync/all-items/` payload. Empty lists arrive as `null`, so every
/// array is optional.
nonisolated struct SimklAllItems: Decodable {
    var movies: [SimklWatchedMovie]
    var shows: [SimklWatchedShow]

    static let empty = SimklAllItems(movies: [], shows: [])

    init(movies: [SimklWatchedMovie], shows: [SimklWatchedShow]) {
        self.movies = movies
        self.shows = shows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movies = try container.decodeIfPresent([SimklWatchedMovie].self, forKey: .movies) ?? []
        let shows = try container.decodeIfPresent([SimklWatchedShow].self, forKey: .shows) ?? []
        let anime = try container.decodeIfPresent([SimklWatchedShow].self, forKey: .anime) ?? []
        self.shows = shows + anime
    }

    enum CodingKeys: String, CodingKey {
        case movies, shows, anime
    }
}

/// One entry from the movies array. Only completed movies count as watched —
/// movies have no "watching" state — but a stray `last_watched_at` is taken as
/// watched regardless of the status it carries.
nonisolated struct SimklWatchedMovie: Decodable {
    let status: String?
    let lastWatchedAt: String?
    let movie: SimklWatchedMedia

    var isWatched: Bool {
        status == "completed" || lastWatchedAt != nil
    }

    enum CodingKeys: String, CodingKey {
        case status
        case lastWatchedAt = "last_watched_at"
        case movie
    }
}

/// One entry from the shows (or anime) array, with the watched seasons and
/// episodes nested beneath it by `extended=full`.
nonisolated struct SimklWatchedShow: Decodable {
    let show: SimklWatchedMedia
    let seasons: [SimklWatchedSeason]

    init(show: SimklWatchedMedia, seasons: [SimklWatchedSeason]) {
        self.show = show
        self.seasons = seasons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        show = try container.decode(SimklWatchedMedia.self, forKey: .show)
        // A missing key means "no episode progress", not a broken response —
        // failing here would abort the whole import.
        seasons = try container.decodeIfPresent([SimklWatchedSeason].self, forKey: .seasons) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case show, seasons
    }
}

nonisolated struct SimklWatchedSeason: Decodable {
    let number: Int
    let episodes: [SimklWatchedEpisode]

    init(number: Int, episodes: [SimklWatchedEpisode]) {
        self.number = number
        self.episodes = episodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        episodes = try container.decodeIfPresent([SimklWatchedEpisode].self, forKey: .episodes) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case number, episodes
    }
}

nonisolated struct SimklWatchedEpisode: Decodable {
    let number: Int
    let lastWatchedAt: String?

    init(number: Int, lastWatchedAt: String?) {
        self.number = number
        self.lastWatchedAt = lastWatchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        // `episode_watched_at=yes` names the timestamp `watched_at`; tolerate
        // the `last_watched_at` spelling too, and a missing key entirely.
        lastWatchedAt = try container.decodeIfPresent(String.self, forKey: .watchedAt)
            ?? container.decodeIfPresent(String.self, forKey: .lastWatchedAt)
    }

    enum CodingKeys: String, CodingKey {
        case number
        case watchedAt = "watched_at"
        case lastWatchedAt = "last_watched_at"
    }
}

/// The id bag shared by watched movies and shows. Simkl mixes integers and
/// strings in its id fields, so the TMDB id decodes either way.
nonisolated struct SimklWatchedMedia: Decodable {
    let ids: SimklWatchedIDs
}

nonisolated struct SimklWatchedIDs: Decodable {
    let tmdb: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let int = try? container.decode(Int.self, forKey: .tmdb) {
            tmdb = int
        } else if let string = try? container.decode(String.self, forKey: .tmdb) {
            tmdb = Int(string)
        } else {
            tmdb = nil
        }
    }

    init(tmdb: Int?) {
        self.tmdb = tmdb
    }

    enum CodingKeys: String, CodingKey {
        case tmdb
    }
}

/// Sentinel used to decode endpoints that legitimately return an empty body.
private nonisolated struct EmptyResponse: Decodable {
    init() {}
    init(from _: Decoder) throws {}
}

private nonisolated extension Data {
    func trimmingJSONWhitespace() -> String {
        (String(data: self, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

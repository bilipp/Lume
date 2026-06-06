//
//  TraktClient.swift
//  Lume
//
//  Stateless networking client for the Trakt API. Covers the OAuth *device*
//  flow (the only flow that works on tvOS, and uniform across every platform),
//  token refresh/revoke, the connected user's profile, watched-history sync,
//  and the watchlist.
//
//  The client id/secret live in the git-ignored `.env` file and are injected
//  into Info.plist at build time by Scripts/inject-env.sh — never committed.
//

import Foundation

// MARK: - Errors

enum TraktError: Error, Equatable {
    case notConfigured
    case invalidResponse
    case server(Int)
    case decoding
    case notAuthenticated

    // Device-flow polling outcomes (per Trakt's documented status codes).
    case authorizationPending // 400 — keep polling
    case slowDown // 429 — poll less often
    case codeExpired // 410 — start over
    case codeDenied // 418 — user rejected
    case codeUsed // 409 — already approved elsewhere
}

// MARK: - Client

/// Read/write Trakt client. Stateless: the caller supplies the access token for
/// authenticated endpoints, so token lifecycle lives in `TraktService`.
nonisolated struct TraktClient {
    static let shared = TraktClient()

    private let baseURL = "https://api.trakt.tv"
    private let session: URLSession
    private let clientID: String?
    private let clientSecret: String?

    /// The pre-filled activation URL the user opens to approve a device code.
    static func activationURL(for userCode: String) -> URL? {
        URL(string: "https://trakt.tv/activate/\(userCode)")
    }

    init(
        session: URLSession = .shared,
        clientID: String? = TraktClient.value(for: "TraktClientID"),
        clientSecret: String? = TraktClient.value(for: "TraktClientSecret")
    ) {
        self.session = session
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Whether usable credentials are present. When false the whole integration
    /// is hidden rather than surfacing errors.
    var isConfigured: Bool {
        guard let clientID, !clientID.isEmpty, !clientID.hasPrefix("$("),
              let clientSecret, !clientSecret.isEmpty, !clientSecret.hasPrefix("$(")
        else { return false }
        return true
    }

    private static func value(for key: String) -> String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - OAuth: device flow

    /// Requests a device + user code to begin authorization.
    func requestDeviceCode() async throws -> TraktDeviceCode {
        guard let clientID, isConfigured else { throw TraktError.notConfigured }
        let body = ["client_id": clientID]
        return try await post("/oauth/device/code", body: body, authorized: false)
    }

    /// Polls once for the token. Maps Trakt's documented polling status codes to
    /// typed errors so `TraktService` can drive the loop.
    func pollForToken(deviceCode: String) async throws -> TraktTokenResponse {
        guard let clientID, let clientSecret, isConfigured else { throw TraktError.notConfigured }
        let body = [
            "code": deviceCode,
            "client_id": clientID,
            "client_secret": clientSecret
        ]
        do {
            return try await post("/oauth/device/token", body: body, authorized: false)
        } catch let TraktError.server(code) {
            switch code {
            case 400: throw TraktError.authorizationPending
            case 404: throw TraktError.invalidResponse
            case 409: throw TraktError.codeUsed
            case 410: throw TraktError.codeExpired
            case 418: throw TraktError.codeDenied
            case 429: throw TraktError.slowDown
            default: throw TraktError.server(code)
            }
        }
    }

    /// Exchanges a refresh token for a fresh token set.
    func refreshToken(_ refreshToken: String) async throws -> TraktTokenResponse {
        guard let clientID, let clientSecret, isConfigured else { throw TraktError.notConfigured }
        let body = [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": "lume://oauth",
            "grant_type": "refresh_token"
        ]
        return try await post("/oauth/token", body: body, authorized: false)
    }

    /// Revokes the access token server-side. Best-effort: failures are ignored
    /// by the caller since the local token is cleared regardless.
    func revokeToken(_ accessToken: String) async throws {
        guard let clientID, let clientSecret, isConfigured else { throw TraktError.notConfigured }
        let body = [
            "token": accessToken,
            "client_id": clientID,
            "client_secret": clientSecret
        ]
        let _: EmptyResponse = try await post("/oauth/revoke", body: body, authorized: false)
    }

    // MARK: - User

    /// The connected user's profile (used to show "Connected as …").
    func currentUser(accessToken: String) async throws -> TraktUser {
        let settings: TraktSettingsResponse = try await get("/users/settings", accessToken: accessToken)
        return settings.user
    }

    // MARK: - Watched history

    /// Adds movies/episodes to the user's watched history.
    func addToHistory(_ items: TraktSyncItems, accessToken: String) async throws {
        let _: TraktSyncResponse = try await post("/sync/history", body: items, accessToken: accessToken)
    }

    /// Removes movies/episodes from the user's watched history.
    func removeFromHistory(_ items: TraktSyncItems, accessToken: String) async throws {
        let _: TraktSyncResponse = try await post("/sync/history/remove", body: items, accessToken: accessToken)
    }

    // MARK: - Watchlist

    /// The user's full watchlist (movies and shows), each carrying its external
    /// ids so the home screen can match against the local library by TMDB id.
    func watchlist(accessToken: String) async throws -> [TraktWatchlistItem] {
        try await get("/sync/watchlist?extended=full", accessToken: accessToken)
    }

    // MARK: - Networking

    private func get<T: Decodable>(_ path: String, accessToken: String? = nil) async throws -> T {
        var request = try makeRequest(path: path, method: "GET", accessToken: accessToken)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    private func post<T: Decodable>(
        _ path: String,
        body: some Encodable,
        authorized: Bool = true,
        accessToken: String? = nil
    ) async throws -> T {
        var request = try makeRequest(path: path, method: "POST", accessToken: authorized ? accessToken : nil)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func makeRequest(path: String, method: String, accessToken: String?) throws -> URLRequest {
        guard let clientID, let url = URL(string: baseURL + path) else { throw TraktError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TraktError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw TraktError.notAuthenticated }
            throw TraktError.server(http.statusCode)
        }

        // Some endpoints (revoke) return an empty body; tolerate that for the
        // sentinel `EmptyResponse` decode.
        if data.isEmpty, let empty = EmptyResponse() as? T {
            return empty
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TraktError.decoding
        }
    }
}

// MARK: - DTOs

/// Decoded `/oauth/device/code` response.
struct TraktDeviceCode: Decodable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURL = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

/// Decoded token response shared by the device-token and refresh endpoints.
struct TraktTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let createdAt: TimeInterval
    let expiresIn: TimeInterval
    let scope: String?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case createdAt = "created_at"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }

    var tokens: TraktTokens {
        TraktTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            createdAt: createdAt,
            expiresIn: expiresIn,
            scope: scope,
            tokenType: tokenType
        )
    }
}

private struct TraktSettingsResponse: Decodable {
    let user: TraktUser
}

struct TraktUser: Decodable {
    let username: String
    let name: String?

    enum CodingKeys: String, CodingKey {
        case username
        case name
    }
}

// MARK: - Sync payloads

/// External-id bag accepted by Trakt sync endpoints. We only ever have a TMDB
/// id from the library, which Trakt resolves on its end.
struct TraktIDs: Codable {
    var tmdb: Int?
    var trakt: Int?
}

struct TraktMoviePayload: Encodable {
    let ids: TraktIDs
}

struct TraktEpisodeNumber: Encodable {
    let number: Int
}

struct TraktSeasonPayload: Encodable {
    let number: Int
    let episodes: [TraktEpisodeNumber]
}

struct TraktShowPayload: Encodable {
    let ids: TraktIDs
    let seasons: [TraktSeasonPayload]
}

/// Body for `/sync/history` (add and remove). Only the populated arrays are
/// encoded.
struct TraktSyncItems: Encodable {
    var movies: [TraktMoviePayload] = []
    var shows: [TraktShowPayload] = []

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !movies.isEmpty { try container.encode(movies, forKey: .movies) }
        if !shows.isEmpty { try container.encode(shows, forKey: .shows) }
    }

    enum CodingKeys: String, CodingKey {
        case movies, shows
    }

    static func movie(tmdbID: Int) -> TraktSyncItems {
        TraktSyncItems(movies: [TraktMoviePayload(ids: TraktIDs(tmdb: tmdbID))])
    }

    static func episode(showTMDBID: Int, season: Int, episode: Int) -> TraktSyncItems {
        TraktSyncItems(shows: [
            TraktShowPayload(
                ids: TraktIDs(tmdb: showTMDBID),
                seasons: [TraktSeasonPayload(number: season, episodes: [TraktEpisodeNumber(number: episode)])]
            )
        ])
    }
}

private struct TraktSyncResponse: Decodable {} // We don't act on the add/remove summary.

// MARK: - Watchlist

/// One watchlist entry. `type` is "movie" or "show"; the matching child carries
/// the title and ids.
struct TraktWatchlistItem: Decodable {
    let type: String
    let movie: TraktWatchlistMedia?
    let show: TraktWatchlistMedia?
}

struct TraktWatchlistMedia: Decodable {
    let title: String?
    let year: Int?
    let ids: TraktIDs
}

/// Sentinel used to decode endpoints that legitimately return an empty body.
private struct EmptyResponse: Decodable {
    init() {}
    init(from _: Decoder) throws {}
}

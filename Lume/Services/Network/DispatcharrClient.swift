//
//  DispatcharrClient.swift
//  Lume
//
//  REST client for a Dispatcharr server's DVR. Authenticates with the user's
//  API key (`X-API-Key`) or with JWTs minted from a username and password and
//  cached in memory (`DispatcharrTokenCache`). Never retries a POST or DELETE:
//  one that failed in flight may still have landed. Never logs a URL, header,
//  key, token or response body — the `users/me` body carries the account's API
//  key in plain text.
//

import Foundation

nonisolated struct DispatcharrClient {
    static let defaultPort = 9191

    /// The 409 a stop gets for a recording that already finished.
    static let recordingFinishedCode = "dispatcharr_recording_finished"

    /// Default JWT lifetimes (0.33.0), used when a token carries no `iat`/`exp`.
    static let accessLifetime: TimeInterval = 30 * 60
    static let refreshLifetime: TimeInterval = 24 * 60 * 60

    let baseURL: URL
    /// `nil` before sign-in: only `version()` works then.
    let credential: DispatcharrCredential?
    /// The zone the server's naive timestamps are written in.
    let serverTimeZone: TimeZone
    private let session: URLSession
    private let tokens: DispatcharrTokenCache
    /// Password mode's cache key, hashed once rather than per request.
    private let tokenKey: DispatcharrTokenCache.Key?
    private let now: @Sendable () -> Date

    init(
        baseURL: URL,
        credential: DispatcharrCredential?,
        serverTimeZone: TimeZone = .gmt,
        session: URLSession = .recordingServer,
        tokens: DispatcharrTokenCache = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.credential = credential
        self.serverTimeZone = serverTimeZone
        self.session = session
        self.tokens = tokens
        tokenKey = if case let .login(username, password)? = credential {
            DispatcharrTokenCache.Key(baseURL: baseURL, username: username, password: password)
        } else {
            nil
        }
        self.now = now
    }

    // MARK: - Endpoints

    /// Unauthenticated: the reachability and identity probe.
    func version() async throws(RecordingServerError) -> DispatcharrVersion {
        try await decode(send(.get, "api/core/version/", authenticated: false))
    }

    func currentUser() async throws(RecordingServerError) -> DispatcharrUser {
        try await decode(send(.get, "api/accounts/users/me/"))
    }

    /// Every channel the account can see, unpaginated.
    func channels() async throws(RecordingServerError) -> [DispatcharrChannel] {
        try await decode(send(.get, "api/channels/channels/"), as: DispatcharrList<DispatcharrChannel>.self).items
    }

    func recordings() async throws(RecordingServerError) -> [DispatcharrRecording] {
        try await decode(send(.get, "api/channels/recordings/"), as: DispatcharrList<DispatcharrRecording>.self).items
    }

    func recording(id: Int) async throws(RecordingServerError) -> DispatcharrRecording {
        try await decode(send(.get, "api/channels/recordings/\(id)/"))
    }

    func createRecording(_ body: DispatcharrRecordingCreate) async throws(RecordingServerError) -> DispatcharrRecording {
        try await decode(send(.post, "api/channels/recordings/", json: body))
    }

    /// Ends a running recording and keeps what it captured. A finished one
    /// fails with `.conflict(code: recordingFinishedCode)`.
    func stopRecording(id: Int) async throws(RecordingServerError) {
        _ = try await send(.post, "api/channels/recordings/\(id)/stop/")
    }

    /// Cancels a scheduled recording, or deletes a finished one with its files.
    func deleteRecording(id: Int) async throws(RecordingServerError) {
        _ = try await send(.delete, "api/channels/recordings/\(id)/")
    }

    /// The finished MKV; supports `Range`.
    func fileURL(id: Int) -> URL {
        url("api/channels/recordings/\(id)/file/")
    }

    /// The live HLS playlist of a running recording. Its segment URLs are
    /// absolute and need the same auth headers.
    func hlsURL(id: Int) -> URL {
        url("api/channels/recordings/\(id)/hls/index.m3u8")
    }

    /// A channel logo. Served to anonymous requests, so an image loader that
    /// sends no credentials can fetch it.
    func logoURL(id: Int) -> URL {
        url("api/channels/logos/\(id)/cache/")
    }

    /// What authorizes a player's requests for a recording's media — the
    /// playlist, every segment and every ranged read of the file — for at
    /// least `validity` from now. Signs in first in password mode.
    func playbackAuthorization(validFor validity: TimeInterval) async throws(RecordingServerError) -> DispatcharrPlaybackAuthorization {
        switch credential {
        case nil:
            throw .unauthorized
        case let .apiKey(key):
            return DispatcharrPlaybackAuthorization(headers: ["X-API-Key": key])
        case .login:
            let session = try await accessSession(validFor: validity)
            return DispatcharrPlaybackAuthorization(headers: ["Authorization": "Bearer \(session.access)"])
        }
    }

    // MARK: - Transport

    enum Method: String {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    private func url(_ path: String) -> URL {
        baseURL.appending(path: path)
    }

    private func send(
        _ method: Method,
        _ path: String,
        body: Data? = nil,
        authenticated: Bool = true
    ) async throws(RecordingServerError) -> Data {
        var request = URLRequest(url: url(path))
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard authenticated else { return try await Self.check(load(request)) }

        switch credential {
        case nil:
            throw .unauthorized
        case let .apiKey(key):
            request.setValue(key, forHTTPHeaderField: "X-API-Key")
            return try await Self.check(load(request))
        case .login:
            let access = try await accessToken()
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await load(request)
            guard response.statusCode == 401 else { return try Self.check((data, response)) }
            if let tokenKey { await tokens.invalidate(tokenKey, access: access) }
            // Never re-send a write: the caller decides whether trying again is safe.
            guard method == .get else { throw .unauthorized }
            let fresh = try await accessToken()
            request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            return try await Self.check(load(request))
        }
    }

    private func send(
        _ method: Method,
        _ path: String,
        json body: some Encodable,
        authenticated: Bool = true
    ) async throws(RecordingServerError) -> Data {
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw .invalidRequest
        }
        return try await send(method, path, body: data, authenticated: authenticated)
    }

    private func load(_ request: URLRequest) async throws(RecordingServerError) -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RecordingServerError.invalidResponse }
            return (data, http)
        } catch {
            throw RecordingServerError(error)
        }
    }

    private static func check(_ result: (Data, HTTPURLResponse)) throws(RecordingServerError) -> Data {
        let (data, response) = result
        guard (200 ..< 300).contains(response.statusCode) else { throw error(status: response.statusCode) }
        return data
    }

    /// DRF status codes as the app's error. Server prose is dropped: it is
    /// unlocalized and may echo input.
    static func error(status: Int) -> RecordingServerError {
        switch status {
        case 400: .invalidRequest
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 409: .conflict(code: recordingFinishedCode)
        case 429: .rateLimited
        default: .server(status: status, code: nil)
        }
    }

    private func decode<T: Decodable>(_ data: Data, as _: T.Type = T.self) throws(RecordingServerError) -> T {
        let decoder = JSONDecoder()
        decoder.userInfo[.dispatcharrNaiveTimeZone] = serverTimeZone
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw .invalidResponse
        }
    }

    // MARK: - JWT

    private func accessToken() async throws(RecordingServerError) -> String {
        try await accessSession(validFor: DispatcharrTokenCache.expiryMargin).access
    }

    private func accessSession(validFor validity: TimeInterval) async throws(RecordingServerError) -> DispatcharrTokenCache.Session {
        guard case let .login(username, password)? = credential, let key = tokenKey else { throw .unauthorized }
        let client = self
        let obtain: DispatcharrTokenCache.Obtain = { previous async throws(RecordingServerError) in
            try await client.obtainSession(previous: previous, username: username, password: password)
        }
        return try await tokens.session(for: key, now: now(), validFor: validity, obtain: obtain)
    }

    /// Refreshes while the refresh token lasts; signs in again only when there
    /// is none or the server rejects it.
    private func obtainSession(
        previous: DispatcharrTokenCache.Session?,
        username: String,
        password: String
    ) async throws(RecordingServerError) -> DispatcharrTokenCache.Session {
        let start = now()
        if let previous, previous.hasValidRefresh(at: start), let refresh = previous.refresh {
            do {
                let pair: DispatcharrTokenPair = try await tokenRequest("api/accounts/token/refresh/", ["refresh": refresh])
                return Self.session(from: pair, start: start, keeping: previous)
            } catch .unauthorized {
                // Refresh token expired or revoked: sign in below.
            }
        }
        let pair: DispatcharrTokenPair = try await tokenRequest(
            "api/accounts/token/", ["username": username, "password": password]
        )
        return Self.session(from: pair, start: start, keeping: nil)
    }

    /// A pair without a refresh token keeps `previous`'s.
    private static func session(
        from pair: DispatcharrTokenPair,
        start: Date,
        keeping previous: DispatcharrTokenCache.Session?
    ) -> DispatcharrTokenCache.Session {
        DispatcharrTokenCache.Session(
            access: pair.access,
            accessExpiry: start.addingTimeInterval(lifetime(of: pair.access, fallback: accessLifetime)),
            refresh: pair.refresh ?? previous?.refresh,
            refreshExpiry: pair.refresh.map {
                start.addingTimeInterval(lifetime(of: $0, fallback: refreshLifetime))
            } ?? previous?.refreshExpiry
        )
    }

    private func tokenRequest(_ path: String, _ body: [String: String]) async throws(RecordingServerError) -> DispatcharrTokenPair {
        try await decode(send(.post, path, json: body, authenticated: false))
    }

    /// A token's lifetime from its own `exp - iat`, so a device clock that
    /// disagrees with the server's can't make every token look expired.
    static func lifetime(of jwt: String, fallback: TimeInterval) -> TimeInterval {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return fallback }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (claims["exp"] as? NSNumber)?.doubleValue,
              let iat = (claims["iat"] as? NSNumber)?.doubleValue,
              exp > iat
        else { return fallback }
        return exp - iat
    }
}

/// How a player authorizes its requests for a recording's media. Never
/// logged: the headers are credentials.
nonisolated struct DispatcharrPlaybackAuthorization: Hashable {
    var headers: [String: String]
}

/// Server only: the credential is a secret and the address a LAN location.
nonisolated extension DispatcharrClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "DispatcharrClient(\(credential.map(String.init(describing:)) ?? "no credential"))"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

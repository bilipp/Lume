//
//  SiloClient.swift
//  Lume
//
//  The few calls Lume makes to a Silo server's own API (`/api/v2`): recognize
//  it, sign in, and ask where its Jellyfin-compatible service listens. Silo
//  runs that service on a separate port for third-party clients, and Lume
//  syncs and plays through it with `JellyfinClient` — the native API is only
//  the front door, so a user can enter the address they open Silo at.
//

import Foundation

nonisolated enum SiloError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case unauthorized
    case notASiloServer
    /// The admin has the Jellyfin-compatible service switched off.
    case compatDisabled
    /// The service was reconfigured and only comes up after a server restart.
    case compatPendingRestart
    /// Signed in, but no candidate address of the compat service answered.
    case compatUnreachable
    case serverError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "The server URL is invalid.")
        case let .networkError(error):
            String(localized: "Network error: \(error.localizedDescription)")
        case .unauthorized:
            String(localized: "The server rejected this username and password.")
        case .notASiloServer:
            String(localized: "Lume couldn't recognize a media server at that address. Enter your Jellyfin, Emby, Plex or Silo server's base address, or the full path of a WebDAV folder.")
        case .compatDisabled:
            String(localized: "Jellyfin compatibility is turned off on this Silo server. Lume connects to Silo through it — ask the server's admin to turn it on in Silo's settings.")
        case .compatPendingRestart:
            String(localized: "Silo's Jellyfin compatibility is waiting for a server restart. Restart Silo and try again.")
        case .compatUnreachable:
            // swiftlint:disable:next line_length
            String(localized: "Lume signed in to Silo but couldn't reach its Jellyfin compatibility service. Make sure the public URL in Silo's Jellyfin compatibility settings is an address this device can reach.")
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
        case .notASiloServer:
            "not a Silo server"
        case .compatDisabled:
            "Jellyfin compatibility disabled"
        case .compatPendingRestart:
            "Jellyfin compatibility pending restart"
        case .compatUnreachable:
            "Jellyfin compatibility unreachable"
        case let .serverError(code):
            "HTTP \(code)"
        case .invalidResponse:
            "unreadable response"
        }
    }
}

/// `GET /api/v2/compat/connect-info`, reduced to the Jellyfin service.
nonisolated struct SiloCompatInfo: Decodable, Hashable {
    let enabled: Bool
    let pendingRestart: Bool
    /// What the admin configured as the service's public address. Often left
    /// at a loopback default, which only the server itself can reach.
    let publicURL: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case pendingRestart = "pending_restart"
        case publicURL = "public_url"
    }
}

private nonisolated struct SiloConnectInfoResponse: Decodable {
    let jellyfin: SiloCompatInfo
}

/// `GET /api/v2/system/info`. Answers without credentials; the API major and
/// the identity link are what tell Silo apart from any other JSON endpoint.
private nonisolated struct SiloSystemInfo: Decodable {
    struct Links: Decodable {
        let identity: String
    }

    let apiMajor: Int
    let links: Links

    enum CodingKeys: String, CodingKey {
        case apiMajor = "api_major"
        case links
    }
}

private nonisolated struct SiloLoginResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

/// `Sendable` for the same reason as `JellyfinClient`: the only stored
/// property is an immutable `URLSession`.
final nonisolated class SiloClient: Sendable {
    let session: URLSession

    init(urlSession: URLSession? = nil) {
        session = urlSession ?? Self.sharedSession
    }

    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": lumeCatalogUserAgent]
        return URLSession(configuration: config)
    }()

    /// The unauthenticated probe for media-server detection.
    func probe(server: URL) async throws {
        let (data, response) = try await send(URLRequest(url: server.appendingPathComponent("api/v2/system/info")))
        guard response.statusCode == 200 else {
            throw SiloError.notASiloServer
        }
        guard let info = try? JSONDecoder().decode(SiloSystemInfo.self, from: data),
              info.apiMajor >= 2, !info.links.identity.isEmpty
        else {
            throw SiloError.notASiloServer
        }
    }

    /// Opens a login session and returns its bearer token.
    func login(server: URL, username: String, password: String) async throws -> String {
        var request = URLRequest(url: server.appendingPathComponent("api/v2/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw SiloError.unauthorized
        default:
            throw SiloError.serverError(response.statusCode)
        }
        guard let login = try? JSONDecoder().decode(SiloLoginResponse.self, from: data), !login.accessToken.isEmpty else {
            throw SiloError.invalidResponse
        }
        return login.accessToken
    }

    func compatInfo(server: URL, token: String) async throws -> SiloCompatInfo {
        var request = URLRequest(url: server.appendingPathComponent("api/v2/compat/connect-info"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw SiloError.unauthorized
        default:
            throw SiloError.serverError(response.statusCode)
        }
        guard let info = try? JSONDecoder().decode(SiloConnectInfoResponse.self, from: data) else {
            throw SiloError.invalidResponse
        }
        return info.jellyfin
    }

    /// Revokes the login session `login` opened. Best effort: the session
    /// only existed to read `compatInfo`, and a failure here must not fail an
    /// add that already succeeded.
    func logout(server: URL, token: String) async {
        var request = URLRequest(url: server.appendingPathComponent("api/v2/auth/logout"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await send(request)
    }

    /// The addresses to try for the Jellyfin-compatible service, best first:
    /// the configured public URL as given, then the same port and path on the
    /// host the user entered — which is the only usable form when the public
    /// URL names a loopback host, and the likely one when it names a host only
    /// the server's own network resolves. With no public URL configured, the
    /// service's default port on the entered host.
    nonisolated static func compatCandidates(publicURL: String, entered: URL) -> [URL] {
        let trimmed = publicURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured = URLComponents(string: trimmed), configured.scheme != nil, let host = configured.host, !host.isEmpty else {
            var fallback = URLComponents()
            fallback.scheme = entered.scheme
            fallback.host = entered.host
            fallback.port = defaultCompatPort
            return [fallback.url].compactMap { $0.map(JellyfinClient.normalizedServerURL) }
        }
        var candidates: [URL] = []
        if !isLoopback(host), let url = configured.url {
            candidates.append(JellyfinClient.normalizedServerURL(url))
        }
        var onEnteredHost = configured
        onEnteredHost.host = entered.host
        if let url = onEnteredHost.url.map(JellyfinClient.normalizedServerURL), !candidates.contains(url) {
            candidates.append(url)
        }
        return candidates
    }

    /// Silo's default listen port for the Jellyfin-compatible service.
    nonisolated static let defaultCompatPort = 8096

    private nonisolated static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "::1" || host == "0.0.0.0" || host.hasPrefix("127.")
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SiloError.networkError(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SiloError.invalidResponse
        }
        return (data, httpResponse)
    }
}

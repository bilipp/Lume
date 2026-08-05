//
//  StalkerSupport.swift
//  Lume
//
//  Shared types for the Stalker (Ministra) portal client: the MAG-style
//  User-Agent, MAC-address handling, the play-command helpers used to defer
//  stream resolution to playback time, the error model, and the in-memory token
//  cache shared across sync and playback.
//

import Foundation

// MARK: - User-Agent

/// The MAG set-top-box User-Agent Stalker portals expect. Portals gate the
/// middleware (`portal.php` / `server/load.php`) behind this UA the same way
/// Xtream panels gate `player_api.php` (see `lumeCatalogUserAgent`): a generic
/// UA gets an HTML error page instead of the `{"js":…}` JSON. This is the widely
/// used MAG250 string.
nonisolated let stalkerUserAgent =
    "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) " +
    "MAG200 stbapp ver: 2 rev: 250 Std Beta. Lib: 2.6.16-15"

// MARK: - MAC address

/// Helpers for the MAC address a Stalker portal authenticates against.
nonisolated enum StalkerMAC {
    /// The MAG vendor OUI prefix portals expect. The trailing three octets
    /// identify the (virtual) device and are what the provider binds the
    /// subscription to.
    static let prefix = "00:1A:79"

    /// Generates a random MAG-style MAC, e.g. `00:1A:79:3F:A2:0B`. Offered as the
    /// add-playlist default so a user without a provider-issued MAC still gets a
    /// well-formed one.
    static func generate() -> String {
        let octets = (0 ..< 3).map { _ in String(format: "%02X", UInt8.random(in: 0 ... 255)) }
        return "\(prefix):\(octets.joined(separator: ":"))"
    }

    /// Whether a string is a syntactically valid `XX:XX:XX:XX:XX:XX` MAC. Accepts
    /// upper- or lower-case hex; the portal is case-insensitive.
    static func isValid(_ mac: String) -> Bool {
        let pattern = "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"
        return mac.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Play command

/// Encodes and decodes the deferred Stalker play command.
///
/// Stalker hands out short-lived stream URLs from `create_link`, so caching them
/// at sync time would leave stale URLs. Instead the catalog stores the channel /
/// VOD **`cmd`** string, and `PlayableMedia` wraps it in a `lumestalker://`
/// placeholder URL. The player resolves the real URL at playback time (see
/// `StalkerStreamResolver`), keeping every `PlayableMedia.from(...)` call site
/// synchronous.
nonisolated enum StalkerLink {
    /// Custom scheme marking a `PlayableMedia.url` that still needs `create_link`
    /// resolution before it can reach a playback engine.
    static let scheme = "lumestalker"

    /// The Stalker content type a command resolves against — `create_link`'s
    /// `type` parameter.
    enum LinkType: String {
        case itv
        case vod
    }

    /// Wraps a Stalker `cmd` in a placeholder URL the resolver can later unpack.
    static func placeholder(type: LinkType, cmd: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "resolve"
        components.queryItems = [
            URLQueryItem(name: "type", value: type.rawValue),
            URLQueryItem(name: "cmd", value: cmd)
        ]
        return components.url
    }

    /// Whether a URL is a deferred Stalker placeholder (vs. an already-playable
    /// URL).
    static func isPlaceholder(_ url: URL) -> Bool {
        url.scheme == scheme
    }

    /// Unpacks a placeholder URL into its `create_link` type and command.
    static func decode(_ url: URL) -> (type: LinkType, cmd: String)? {
        guard url.scheme == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let cmd = items.first(where: { $0.name == "cmd" })?.value,
              let typeRaw = items.first(where: { $0.name == "type" })?.value,
              let type = LinkType(rawValue: typeRaw)
        else { return nil }
        return (type, cmd)
    }

    /// Query parameters embedded in a direct-URL `cmd`, re-exposed as top-level
    /// `create_link` parameters. Xtream-UI-style Stalker emulations hand out
    /// channel cmds that are full stream URLs
    /// (`ffmpeg http://host/play/live.php?mac=…&stream=933136&extension=ts&play_token=…`)
    /// and their `create_link` never parses the percent-encoded `cmd` it
    /// receives — it reads `stream` / `extension` from the request's own query
    /// string and answers with an empty `stream=` (an unplayable URL) when
    /// they're missing. Forwarding the embedded parameters satisfies those
    /// portals, while genuine Ministra portals resolve the full `cmd` and
    /// ignore the extras. `mac` and `play_token` stay out — the portal derives
    /// the MAC from the session and mints a fresh token; the stored one is
    /// stale by playback time.
    static func forwardedQueryItems(from cmd: String) -> [URLQueryItem] {
        guard let url = resolvedURL(from: cmd),
              url.scheme == "http" || url.scheme == "https",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [] }
        let excluded: Set = ["mac", "play_token", "token", "type", "action", "cmd", "JsHttpRequest"]
        return items.filter { !excluded.contains($0.name) }
    }

    /// Extracts a playable URL from a `create_link` `cmd` response. Portals
    /// commonly prefix the URL with an engine token (`ffmpeg `, `auto `) and may
    /// append params, so we take the first `http(s)` token rather than trusting
    /// the whole string.
    static func resolvedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "https?://", options: .regularExpression) else {
            return URL(string: trimmed)
        }
        let urlPart = String(trimmed[range.lowerBound...])
        // The URL runs to the next whitespace (params after a space aren't part
        // of the URL).
        let urlString = urlPart.split(whereSeparator: { $0 == " " }).first.map(String.init) ?? urlPart
        return URL(string: urlString)
    }
}

// MARK: - Errors

enum StalkerError: LocalizedError {
    case invalidURL
    case handshakeFailed
    case authenticationFailed
    case noStreamURL
    case networkError(Error)
    case decodingError(Error)
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The portal URL is invalid."
        case .handshakeFailed:
            "Couldn't connect to the Stalker portal. Check the portal URL and MAC address."
        case .authenticationFailed:
            "The portal rejected this MAC address. It may not be authorized, or its subscription has expired."
        case .noStreamURL:
            "The portal didn't return a playable stream for this item."
        case let .networkError(error):
            "Network error: \(error.localizedDescription)"
        case let .decodingError(error):
            "Failed to read the portal response: \(error.localizedDescription)"
        case .invalidResponse:
            "Received an invalid response from the portal."
        case let .serverError(code):
            "Portal error (HTTP \(code))."
        }
    }

    /// Credential-free summary for diagnostic logs. Interpolated with
    /// `privacy: .public` so user-exported logs stay actionable — which means
    /// it must never contain a URL: Stalker portal links carry the MAC
    /// address and short-lived tokens, and underlying `NSError` descriptions
    /// can embed the failing URL.
    var logDescription: String {
        switch self {
        case .invalidURL:
            return "invalid portal URL"
        case .handshakeFailed:
            return "portal handshake failed"
        case .authenticationFailed:
            return "portal rejected the MAC address"
        case .noStreamURL:
            return "no playable stream in portal response"
        case let .networkError(error):
            let nsError = error as NSError
            return "network error (\(nsError.domain) \(nsError.code))"
        case let .decodingError(error):
            let nsError = error as NSError
            return "undecodable portal response (\(nsError.domain) \(nsError.code))"
        case .invalidResponse:
            return "non-HTTP response"
        case let .serverError(code):
            return "HTTP \(code)"
        }
    }

    /// Whether the failure is likely transient and worth retrying.
    var isRetriable: Bool {
        switch self {
        case .networkError:
            true
        case let .serverError(code):
            code >= 500
        case .invalidURL, .handshakeFailed, .authenticationFailed, .noStreamURL,
             .decodingError, .invalidResponse:
            false
        }
    }

    var isAuthFailure: Bool {
        switch self {
        case .authenticationFailed, .handshakeFailed: true
        default: false
        }
    }
}

// MARK: - Session cache

/// In-memory cache of authenticated Stalker sessions, keyed by portal+MAC.
///
/// A handshake yields a bearer token and pins the working middleware endpoint
/// (`portal.php` vs `server/load.php`). Both are reused across catalog sync and
/// stream resolution so the app handshakes once per portal rather than per
/// request. Tokens are session-scoped and intentionally **not** persisted — they
/// expire, and re-handshaking is cheap.
actor StalkerSessionStore {
    static let shared = StalkerSessionStore()

    struct Session {
        let token: String
        let endpoint: URL
    }

    private var sessions: [String: Session] = [:]

    func session(for key: String) -> Session? {
        sessions[key]
    }

    func store(_ session: Session, for key: String) {
        sessions[key] = session
    }

    func clear(_ key: String) {
        sessions[key] = nil
    }
}

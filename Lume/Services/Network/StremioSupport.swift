//
//  StremioSupport.swift
//  Lume
//
//  Shared types for the Stremio addon client: manifest-URL normalization, the
//  deferred play-link helpers used to resolve stream URLs at playback time, and
//  the error model.
//

import Foundation

// MARK: - Manifest URL

/// Helpers for the addon manifest URL a Stremio source is keyed on.
nonisolated enum StremioManifestURL {
    static let suffix = "/manifest.json"

    /// Normalizes user input into a fetchable manifest URL: trims whitespace,
    /// converts the `stremio://` install-link scheme to `https://`, and appends
    /// `/manifest.json` when the user pasted just the addon's base URL.
    static func normalized(_ raw: String) -> String {
        var urlString = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if urlString.lowercased().hasPrefix("stremio://") {
            urlString = "https://" + urlString.dropFirst("stremio://".count)
        }
        while urlString.hasSuffix("/") {
            urlString = String(urlString.dropLast())
        }
        if !urlString.isEmpty, !urlString.lowercased().hasSuffix(suffix) {
            urlString += suffix
        }
        return urlString
    }

    /// The addon's base URL — the manifest URL with the trailing
    /// `/manifest.json` stripped. Any path before it (addons commonly embed a
    /// user-configuration segment) is preserved.
    static func baseURL(of manifestURL: String) -> URL? {
        var urlString = manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if urlString.lowercased().hasSuffix(suffix) {
            urlString = String(urlString.dropLast(suffix.count))
        }
        return URL(string: urlString)
    }
}

// MARK: - Play link

/// Encodes and decodes the deferred Stremio play link.
///
/// Stremio addons hand out stream URLs from `/stream/{type}/{id}.json` on
/// demand, and those URLs can be short-lived or debrid-session-bound — so the
/// catalog stores a `lumestremio://` placeholder carrying the content type and
/// Stremio id, and the player resolves the real URL at playback time (see
/// `StremioStreamResolver`). Mirrors `StalkerLink`.
nonisolated enum StremioLink {
    /// Custom scheme marking a `PlayableMedia.url` that still needs stream
    /// resolution before it can reach a playback engine.
    static let scheme = "lumestremio"

    /// Wraps a Stremio content type and id in a placeholder URL the resolver
    /// can later unpack. `type` is the addon's own type string (`movie`,
    /// `series`, `tv`, `channel`); `id` is the meta or video id (e.g.
    /// `tt0898266` or `tt0898266:9:17`).
    static func placeholder(type: String, id: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "resolve"
        components.queryItems = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "id", value: id)
        ]
        return components.url
    }

    /// Whether a URL is a deferred Stremio placeholder (vs. an already-playable
    /// URL).
    static func isPlaceholder(_ url: URL) -> Bool {
        url.scheme == scheme
    }

    /// Unpacks a placeholder URL into its content type and Stremio id.
    static func decode(_ url: URL) -> (type: String, id: String)? {
        guard url.scheme == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let type = items.first(where: { $0.name == "type" })?.value,
              let id = items.first(where: { $0.name == "id" })?.value
        else { return nil }
        return (type, id)
    }
}

// MARK: - Errors

enum StremioError: LocalizedError {
    case invalidURL
    case manifestUnavailable
    case noStreamURL
    case networkError(Error)
    case decodingError(Error)
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The addon URL is invalid."
        case .manifestUnavailable:
            "Couldn't load the addon manifest. Check the addon URL."
        case .noStreamURL:
            "The addon didn't return a playable stream for this item."
        case let .networkError(error):
            "Network error: \(error.localizedDescription)"
        case let .decodingError(error):
            "Failed to read the addon response: \(error.localizedDescription)"
        case .invalidResponse:
            "Received an invalid response from the addon."
        case let .serverError(code):
            "Addon error (HTTP \(code))."
        }
    }

    /// Whether the failure is likely transient and worth retrying.
    var isRetriable: Bool {
        switch self {
        case .networkError:
            true
        case let .serverError(code):
            code >= 500
        case .invalidURL, .manifestUnavailable, .noStreamURL,
             .decodingError, .invalidResponse:
            false
        }
    }
}

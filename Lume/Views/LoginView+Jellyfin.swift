//
//  LoginView+Jellyfin.swift
//  Lume
//
//  The Jellyfin/Emby connection test and the copy that tells its failure modes
//  apart: probe the public endpoint first (wrong address vs. wrong credentials
//  need different actions from the user), then log in. The two products are
//  wire-compatible, so one check serves both and the probe decides which it
//  is. The form fields moved to `MediaServerLoginSection` /
//  `MediaServerLoginFields` (LoginView+MediaServer.swift), which detects the
//  server kind from the URL and delegates here.
//

import Foundation

// MARK: - Connection test

/// The add-playlist connection test for a Jellyfin or Emby server and the copy
/// for its failures: probe the public endpoint first (wrong address vs. wrong
/// credentials need different actions from the user), then log in.
enum JellyfinAddCheck {
    struct Input: Hashable {
        var url: String
        var username: String
        var password: String
    }

    struct Verified {
        /// The base URL to store, without a trailing slash.
        var serverURL: String
        var flavor: MediaServerFlavor
        var session: JellyfinSession
    }

    /// Returns what to store on success. `urlSession` is a test seam (see
    /// `MediaServerAddCheck.verify`); production callers leave it `nil`.
    static func verify(_ input: Input, urlSession: URLSession? = nil) async throws -> Verified {
        let trimmed = input.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw JellyfinError.invalidURL
        }
        let server = JellyfinClient.normalizedServerURL(url)
        let client = JellyfinClient(urlSession: urlSession)
        // Probe first: it answers without credentials, so a wrong host fails
        // here instead of surfacing as a login error. It also decides whether
        // this is Jellyfin or Emby.
        let flavor = try await client.probe(server: server)
        let user = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = try await client.authenticate(server: server, username: user, password: input.password)
        return Verified(serverURL: server.absoluteString, flavor: flavor, session: session)
    }

    static func message(for error: Error, input: Input, timedOut: Bool) -> String {
        let host = URL(string: input.url.trimmingCharacters(in: .whitespacesAndNewlines))?.host
        if timedOut, ServerAddressHelp.isLocalHost(host) {
            return ServerAddressHelp.localNetworkMessage
        }
        guard let jellyfinError = error as? JellyfinError else { return error.localizedDescription }
        switch jellyfinError {
        case .unauthorized:
            return String(localized: "The server rejected this username and password.")
        case .notAMediaServer:
            return String(localized: "That URL doesn't answer as a Jellyfin or Emby server. Enter the server's base address, e.g. http://192.168.1.10:8096.")
        case let .networkError(underlying) where ServerAddressHelp.isLocalHost(host) && ServerAddressHelp.isUnreachable(underlying):
            return ServerAddressHelp.localNetworkMessage
        default:
            return jellyfinError.localizedDescription
        }
    }

    // The local-network copy and the private-address classifier live in
    // `ServerAddressHelp`, shared with the WebDAV and media-server checks.
}

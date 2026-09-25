//
//  LoginView+Plex.swift
//  Lume
//
//  The Plex connection test and the copy that tells its failure modes apart.
//  Plex has no per-user login against the server itself: everything is gated
//  on an `X-Plex-Token`, which can come from three places. They are tried in
//  the order below, so the one media-server form covers every setup without
//  asking the user which kind of credential they have.
//
//  The form fields live in `MediaServerLoginSection` /
//  `MediaServerLoginFields` (LoginView+MediaServer.swift), which detects Plex
//  from the URL and delegates here.
//

import Foundation

enum PlexAddCheck {
    struct Input: Hashable {
        var url: String
        var username: String
        var password: String
    }

    struct Verified {
        /// The base URL to store, without a trailing slash.
        var serverURL: String
        /// `nil` for a server that allows unauthenticated access on the local
        /// network — there is genuinely no credential to keep.
        var token: String?
    }

    /// Returns what to store on success. `urlSession` is a test seam (see
    /// `MediaServerAddCheck.verify`); production callers leave it `nil`.
    ///
    /// The three token sources, in order:
    /// 1. **username + password** — a plex.tv sign-in, which is what most
    ///    users have. Two-factor accounts append the current code to the
    ///    password, exactly as Plex's own clients expect.
    /// 2. **no credential** — the server is asked for its sections
    ///    unauthenticated. Only a server with "allow unauthenticated access
    ///    on the local network" answers, and that playlist stores no token.
    /// 3. **password only** — treated as a pasted `X-Plex-Token`, used when
    ///    the unauthenticated attempt was refused.
    static func verify(_ input: Input, urlSession: URLSession? = nil, accountBaseURL: URL? = nil) async throws -> Verified {
        let trimmed = input.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw PlexError.invalidURL
        }
        let server = PlexClient.normalizedServerURL(url)
        let client = PlexClient(urlSession: urlSession, accountBaseURL: accountBaseURL)
        // Probe first: it answers without a token, so a wrong host fails here
        // instead of surfacing as an authentication error.
        try await client.probe(server: server)

        let token = try await resolveToken(input, client: client, server: server)
        // Whichever source produced it, the token only counts once the server
        // itself has accepted it.
        _ = try await client.sections(server: server, token: token)
        return Verified(serverURL: server.absoluteString, token: token)
    }

    /// Deliberately prefers *no* token over a pasted one: a server with
    /// unauthenticated local access answers metadata for any token value at
    /// all — including a wrong one — but serves the media itself with a 503.
    /// Storing a token such a server never needed would turn a library that
    /// browses perfectly into one where nothing plays, and nothing in the
    /// add-playlist flow would have caught it.
    private static func resolveToken(_ input: Input, client: PlexClient, server: URL) async throws -> String? {
        let user = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = input.password.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty, !secret.isEmpty {
            return try await client.signIn(username: user, password: input.password)
        }
        do {
            _ = try await client.sections(server: server, token: nil)
            return nil
        } catch PlexError.unauthorized {
            guard !secret.isEmpty else { throw PlexError.unauthorized }
            return secret
        }
    }

    static func message(for error: Error, input: Input, timedOut: Bool) -> String {
        let host = URL(string: input.url.trimmingCharacters(in: .whitespacesAndNewlines))?.host
        if timedOut, ServerAddressHelp.isLocalHost(host) {
            return ServerAddressHelp.localNetworkMessage
        }
        guard let plexError = error as? PlexError else { return error.localizedDescription }
        switch plexError {
        case .unauthorized:
            return unauthorizedMessage(for: input)
        case .notAPlexServer:
            return String(localized: "That URL doesn't answer as a Plex server. Enter the server's base address, e.g. http://192.168.1.10:32400.")
        case let .networkError(underlying) where ServerAddressHelp.isLocalHost(host) && ServerAddressHelp.isUnreachable(underlying):
            return ServerAddressHelp.localNetworkMessage
        default:
            return plexError.localizedDescription
        }
    }

    /// A 401 means something different for each of the three token sources,
    /// and each needs a different action from the user.
    private static func unauthorizedMessage(for input: Input) -> String {
        let user = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = input.password.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty, !secret.isEmpty {
            return String(localized: "Plex rejected this account. Check your username and password — with two-factor authentication, add the current code to the end of the password.")
        }
        if !secret.isEmpty {
            return String(localized: "This Plex server rejected that token. Paste the X-Plex-Token from your server, or enter your Plex account's username and password instead.")
        }
        return String(localized: "This Plex server needs a sign-in. Enter your Plex account's username and password, or paste an X-Plex-Token in the password field.")
    }
}

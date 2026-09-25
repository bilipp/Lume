//
//  LoginView+WebDAV.swift
//  Lume
//
//  The WebDAV half of the add-playlist form: the fields, the connection test
//  and the copy that tells its four failure modes apart.
//

import Foundation

// The form fields moved to `MediaServerLoginSection` / `MediaServerLoginFields`
// (LoginView+MediaServer.swift): the form no longer asks for the server kind
// upfront, it detects Jellyfin vs. WebDAV from the URL. Playlist construction
// moved to `addMediaServerPlaylist` there for the same reason; what stays here
// is the WebDAV connection test and its failure copy, which the media-server
// check delegates to.

// MARK: - Connection test

/// The add-playlist connection test for a WebDAV share and the copy for its
/// failures. Each of the four outcomes needs a different action from the user,
/// and a bare `localizedDescription` collapses three of them into "it failed".
enum WebDAVAddCheck {
    struct Input: Hashable {
        var url: String
        var username: String
        var password: String
    }

    /// A share that lists nothing is almost always the wrong path: the share
    /// root is not discoverable (an Apache `Alias` never shows up in a PROPFIND
    /// of the server root), so "just the hostname" answers with an empty or
    /// unrelated listing rather than an error.
    enum AddError: Error {
        case emptyShare
    }

    /// Returns the URL to store on success. `urlSession` is a test seam (see
    /// `MediaServerAddCheck.verify`); production callers leave it `nil`.
    static func verify(_ input: Input, urlSession: URLSession? = nil) async throws -> String {
        let trimmed = input.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.host != nil else { throw WebDAVError.invalidURL }

        let user = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = user.isEmpty ? nil : WebDAVCredentials(username: user, password: input.password)
        let client = WebDAVClient(urlSession: urlSession)
        // Depth 0 first: it answers as fast on a share with thousands of files
        // as on an empty one, so a wrong host or a wrong password fails without
        // waiting out a listing.
        try await client.probe(url, credentials: credentials)
        guard try await !client.list(url, credentials: credentials).isEmpty else {
            throw AddError.emptyShare
        }
        return url.absoluteString
    }

    static func message(for error: Error, input: Input, timedOut: Bool) -> String {
        let host = URL(string: input.url.trimmingCharacters(in: .whitespacesAndNewlines))?.host
        if timedOut, ServerAddressHelp.isLocalHost(host) { return ServerAddressHelp.localNetworkMessage }
        if error is AddError { return emptyShareMessage }
        guard let webdavError = error as? WebDAVError else { return error.localizedDescription }
        switch webdavError {
        case .unauthorized:
            return String(localized: "The server rejected this username and password. Leave both empty if the share allows anonymous access.")
        case .notAWebDAVServer:
            return String(localized: "That URL doesn't answer as a WebDAV share. Enter the full path of the shared folder, not just the server address.")
        case let .networkError(underlying) where ServerAddressHelp.isLocalHost(host) && ServerAddressHelp.isUnreachable(underlying):
            return ServerAddressHelp.localNetworkMessage
        default:
            return webdavError.localizedDescription
        }
    }

    private static var emptyShareMessage: String {
        String(localized: "That folder is empty. Enter the full path of the folder that holds your media — a server's root address usually lists nothing.")
    }

    // The local-network copy and the private-address classifier live in
    // `ServerAddressHelp`, shared with the Jellyfin and media-server checks.
}

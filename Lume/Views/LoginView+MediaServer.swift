//
//  LoginView+MediaServer.swift
//  Lume
//
//  The Media Server half of the add-playlist form: one URL field whose server
//  kind — Jellyfin, WebDAV, and later Plex/Emby — is detected, not picked.
//  Detection lives here; the per-kind connection tests stay in
//  `WebDAVAddCheck` / `JellyfinAddCheck`, which this delegates to.
//

import SwiftUI

// MARK: - Fields

#if !os(tvOS)
    /// The media-server fields of the add-playlist form. A `Section`, so it
    /// composes into `LoginView`'s `Form` the same way the inline source
    /// sections do.
    struct MediaServerLoginSection: View {
        @Binding var name: String
        @Binding var serverURL: String
        @Binding var username: String
        @Binding var password: String

        var body: some View {
            Section {
                TextField("e.g. My Media Server", text: $name)
                    .textContentType(.name)

                TextField("e.g. http://192.168.1.10:8096", text: $serverURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.URL)

                TextField("Username (optional)", text: $username)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.username)

                SecureField("Password (optional)", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Media Server")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enter your server address — Lume recognizes Jellyfin servers and WebDAV shares automatically.")
                    Text("For a WebDAV share, enter the full path of the folder that holds your media — a server's root address usually isn't browsable.")
                    Text("Leave the username and password empty for an anonymous share.")
                    Text("The first connection asks permission to find devices on your local network. If you decline it, only the system Settings app can allow it again.")
                }
            }
        }
    }
#endif

#if os(tvOS)
    /// The tvOS counterpart: bare labelled fields, since the tvOS form has no
    /// `Section` chrome and supplies its own name field.
    struct MediaServerLoginFields: View {
        @Binding var serverURL: String
        @Binding var username: String
        @Binding var password: String

        var body: some View {
            TVSettingsField(title: "Server URL", placeholder: "e.g. http://192.168.1.10:8096", text: $serverURL, contentType: .URL)
            TVSettingsField(title: "Username (optional)", placeholder: "Username", text: $username, contentType: .username)
            TVSettingsField(title: "Password (optional)", placeholder: "Password", text: $password, isSecure: true, contentType: .password)
        }
    }
#endif

// MARK: - Add playlist

extension LoginView {
    func addMediaServerPlaylist() {
        isLoading = true
        errorMessage = nil

        let playlistName = trimmedName.isEmpty ? "My Playlist" : trimmedName
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = MediaServerAddCheck.Input(url: mediaServerURL, username: user, password: password)

        Task {
            do {
                try await withConnectionTimeout {
                    switch try await MediaServerAddCheck.verify(input) {
                    case let .jellyfin(serverURL, session):
                        insertAndFinish(Playlist(
                            name: playlistName,
                            jellyfinURL: serverURL,
                            username: user,
                            password: password,
                            accessToken: session.accessToken,
                            userId: session.userId
                        ))
                    case let .webdav(url):
                        // An anonymous share stores no password: a stray one
                        // would be sent as a Basic header the server never
                        // asked for.
                        insertAndFinish(Playlist(
                            name: playlistName,
                            webdavURL: url,
                            username: user,
                            password: user.isEmpty ? "" : password
                        ))
                    }
                }
            } catch {
                errorMessage = MediaServerAddCheck.message(for: error, input: input, timedOut: error is ConnectionTimeoutError)
                isLoading = false
            }
        }
    }
}

// MARK: - Detection & connection test

/// The server kinds the media-server entry point detects. New kinds (Plex,
/// Emby, …) add a case here, a probe in `detect`, and a branch in `verify` —
/// the form, the playlist construction and the message mapping follow.
enum MediaServerType {
    case jellyfin
    case webdav
}

enum MediaServerError: Error, Equatable {
    /// Neither probe recognized the address.
    case unsupported
    /// A Jellyfin server was detected but no username was entered.
    case missingCredentials
}

enum MediaServerAddCheck {
    struct Input: Hashable {
        var url: String
        var username: String
        var password: String
    }

    /// What to store on success, per detected kind.
    enum Verified {
        case jellyfin(serverURL: String, session: JellyfinSession)
        case webdav(url: String)
    }

    /// Detects the kind, then runs that kind's connection test. The detection
    /// probes are cheap and unauthenticated; each kind's `verify` re-probes
    /// with credentials, so every flow keeps its single source of truth.
    ///
    /// `urlSession` is a test seam: the checks build their clients on it, so a
    /// stubbed session drives the whole flow without touching the network.
    /// Production callers leave it `nil`.
    static func verify(_ input: Input, urlSession: URLSession? = nil) async throws -> Verified {
        let trimmed = input.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw JellyfinError.invalidURL
        }
        switch try await detect(server: url, urlSession: urlSession) {
        case .jellyfin:
            let user = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty else {
                throw MediaServerError.missingCredentials
            }
            let verified = try await JellyfinAddCheck.verify(.init(url: input.url, username: user, password: input.password), urlSession: urlSession)
            return .jellyfin(serverURL: verified.serverURL, session: verified.session)
        case .webdav:
            let user = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = try await WebDAVAddCheck.verify(.init(url: input.url, username: user, password: input.password), urlSession: urlSession)
            return .webdav(url: url)
        }
    }

    /// Runs the two probes in order: Jellyfin's public endpoint answers
    /// without credentials, so a Jellyfin server is recognized before any
    /// login attempt. A `401` to the WebDAV probe still means WebDAV — a
    /// share demanding credentials.
    ///
    /// Network errors pass through untouched (a dead host fails both probes,
    /// and the address deserves the local-network copy, not "unsupported").
    /// Anything else that rules out both kinds surfaces as `unsupported`.
    static func detect(server: URL, urlSession: URLSession? = nil) async throws -> MediaServerType {
        do {
            try await JellyfinClient(urlSession: urlSession).probe(server: server)
            return .jellyfin
        } catch let error as JellyfinError {
            if case .networkError = error {
                // Remembered only to prefer it below: see WebDAV arm.
                return try await detectWebDAV(server: server, urlSession: urlSession, jellyfinNetworkError: error)
            }
        }
        return try await detectWebDAV(server: server, urlSession: urlSession, jellyfinNetworkError: nil)
    }

    private static func detectWebDAV(server: URL, urlSession: URLSession?, jellyfinNetworkError: JellyfinError?) async throws -> MediaServerType {
        do {
            try await WebDAVClient(urlSession: urlSession).probe(server, credentials: nil)
            return .webdav
        } catch WebDAVError.unauthorized {
            return .webdav
        } catch let error as WebDAVError {
            if case .networkError = error {
                throw jellyfinNetworkError ?? error
            }
            throw MediaServerError.unsupported
        }
    }

    static func message(for error: Error, input: Input, timedOut: Bool) -> String {
        let host = URL(string: input.url.trimmingCharacters(in: .whitespacesAndNewlines))?.host
        if timedOut, ServerAddressHelp.isLocalHost(host) {
            return ServerAddressHelp.localNetworkMessage
        }
        if error is JellyfinError {
            return JellyfinAddCheck.message(
                for: error,
                input: .init(url: input.url, username: input.username, password: input.password),
                timedOut: false
            )
        }
        if error is WebDAVError || error is WebDAVAddCheck.AddError {
            return WebDAVAddCheck.message(
                for: error,
                input: .init(url: input.url, username: input.username, password: input.password),
                timedOut: false
            )
        }
        guard let serverError = error as? MediaServerError else {
            return error.localizedDescription
        }
        switch serverError {
        case .unsupported:
            return String(localized: "Lume couldn't recognize a media server at that address. Enter your Jellyfin server's base address, or the full path of a WebDAV folder.")
        case .missingCredentials:
            return String(localized: "This Jellyfin server needs a username and password. Enter them and try again.")
        }
    }

    /// tvOS hint copy. One line, because the tvOS form shows a single hint
    /// under the fields.
    static var hint: LocalizedStringKey {
        "Enter your server address — Jellyfin and WebDAV are detected automatically. A declined local network prompt can only be allowed again in Settings."
    }
}

// MARK: - Shared address copy

/// The local-network explanation and the private-address classifier, shared by
/// all three add-playlist connection tests so the copy and the ranges stay
/// identical wherever a URL is entered.
enum ServerAddressHelp {
    /// A declined local-network prompt is indistinguishable from an unreachable
    /// host: iOS and tvOS just fail the connection. Only the system Settings app
    /// can reverse it, and on tvOS there is no other affordance at all.
    static var localNetworkMessage: String {
        String(localized: "Lume couldn't reach that address on your local network. If you declined the local network prompt, only the system Settings app can allow it again.")
    }

    static func isLocalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        let parts = host.split(separator: ".")
        if parts.count == 4, parts[0] == "172", let block = Int(parts[1]), (16 ... 31).contains(block) {
            return true
        }
        return false
    }

    static func isUnreachable(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet
        ].contains(nsError.code)
    }
}

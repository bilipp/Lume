//
//  LoginView+MediaServer.swift
//  Lume
//
//  The Media Server half of the add-playlist form: one URL field whose server
//  kind — Jellyfin, Emby, Plex or WebDAV — is detected, not picked. Detection
//  lives here; the per-kind connection tests stay in `WebDAVAddCheck` /
//  `JellyfinAddCheck` / `PlexAddCheck`, which this delegates to.
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
                    Text("Enter your server address — Lume recognizes Jellyfin, Emby and Plex servers and WebDAV shares automatically.")
                    Text("For a WebDAV share, enter the full path of the folder that holds your media — a server's root address usually isn't browsable.")
                    Text("Leave the username and password empty for an anonymous share. For Plex, enter your Plex account — or paste an X-Plex-Token in the password field.")
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
                    case let .mediaServer(serverURL, flavor, session):
                        insertAndFinish(Playlist(
                            name: playlistName,
                            mediaServerURL: serverURL,
                            flavor: flavor,
                            username: user,
                            password: password,
                            accessToken: session.accessToken,
                            userId: session.userId
                        ))
                    case let .plex(serverURL, token):
                        // Only the resolved token is stored: the plex.tv
                        // password bought it and has no further use, and a
                        // server that answers unauthenticated stores nothing
                        // at all.
                        insertAndFinish(Playlist(
                            name: playlistName,
                            plexURL: serverURL,
                            username: user,
                            accessToken: token
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

/// The server kinds the media-server entry point detects. A new kind adds a
/// case here, a probe in `detect`, and a branch in `verify` — the form, the
/// playlist construction and the message mapping follow.
enum MediaServerType: Equatable {
    /// Jellyfin and Emby, which share one API and one connection test; the
    /// flavour only decides which product the copy and the rows name.
    case mediaServer(MediaServerFlavor)
    case plex
    case webdav
}

enum MediaServerError: Error, Equatable {
    /// No probe recognized the address.
    case unsupported
    /// A Jellyfin or Emby server was detected but no username was entered.
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
        case mediaServer(serverURL: String, flavor: MediaServerFlavor, session: JellyfinSession)
        /// `token` is `nil` for a server that allows unauthenticated access
        /// on the local network.
        case plex(serverURL: String, token: String?)
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
        case .mediaServer:
            let user = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty else {
                throw MediaServerError.missingCredentials
            }
            let verified = try await JellyfinAddCheck.verify(.init(url: input.url, username: user, password: input.password), urlSession: urlSession)
            return .mediaServer(serverURL: verified.serverURL, flavor: verified.flavor, session: verified.session)
        case .plex:
            // Plex needs no username: the token can come from a pasted value
            // or from a server that allows unauthenticated local access, so
            // there is nothing to require up front.
            let user = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let verified = try await PlexAddCheck.verify(.init(url: input.url, username: user, password: input.password), urlSession: urlSession)
            return .plex(serverURL: verified.serverURL, token: verified.token)
        case .webdav:
            let user = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = try await WebDAVAddCheck.verify(.init(url: input.url, username: user, password: input.password), urlSession: urlSession)
            return .webdav(url: url)
        }
    }

    /// Runs the probes in order, cheapest and most specific first: the
    /// Jellyfin/Emby public endpoint and Plex's `/identity` both answer
    /// without credentials, so either is recognized before any login attempt,
    /// and WebDAV — the one kind with no identifying endpoint — is left last.
    /// A `401` to the WebDAV probe still means WebDAV: a share demanding
    /// credentials.
    ///
    /// Network errors pass through untouched (a dead host fails every probe,
    /// and the address deserves the local-network copy, not "unsupported").
    /// Anything else that rules out every kind surfaces as `unsupported`.
    static func detect(server: URL, urlSession: URLSession? = nil) async throws -> MediaServerType {
        // Remembered only to prefer it in the WebDAV arm below: a host that is
        // simply unreachable should report that, not "unsupported".
        var networkError: Error?
        do {
            return try await .mediaServer(JellyfinClient(urlSession: urlSession).probe(server: server))
        } catch let error as JellyfinError {
            if case .networkError = error {
                networkError = error
            }
        }
        do {
            try await PlexClient(urlSession: urlSession).probe(server: server)
            return .plex
        } catch let error as PlexError {
            if case .networkError = error, networkError == nil {
                networkError = error
            }
        }
        return try await detectWebDAV(server: server, urlSession: urlSession, earlierNetworkError: networkError)
    }

    private static func detectWebDAV(server: URL, urlSession: URLSession?, earlierNetworkError: Error?) async throws -> MediaServerType {
        do {
            try await WebDAVClient(urlSession: urlSession).probe(server, credentials: nil)
            return .webdav
        } catch WebDAVError.unauthorized {
            return .webdav
        } catch let error as WebDAVError {
            if case .networkError = error {
                throw earlierNetworkError ?? error
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
        if error is PlexError {
            return PlexAddCheck.message(
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
            return String(localized: "Lume couldn't recognize a media server at that address. Enter your Jellyfin, Emby or Plex server's base address, or the full path of a WebDAV folder.")
        case .missingCredentials:
            return String(localized: "This server needs a username and password. Enter them and try again.")
        }
    }

    /// tvOS hint copy. One line, because the tvOS form shows a single hint
    /// under the fields.
    static var hint: LocalizedStringKey {
        "Enter your server address — Jellyfin, Emby, Plex and WebDAV are detected automatically. A declined local network prompt can only be allowed again in Settings."
    }
}

// MARK: - Shared address copy

/// The local-network explanation and the private-address classifier, shared by
/// every add-playlist connection test so the copy and the ranges stay
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

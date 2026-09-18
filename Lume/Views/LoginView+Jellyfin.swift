//
//  LoginView+Jellyfin.swift
//  Lume
//
//  The Jellyfin half of the add-playlist form: the fields, the connection test
//  and the copy that tells its failure modes apart. Mirrors LoginView+WebDAV.
//

import SwiftUI

// MARK: - Fields

#if !os(tvOS)
    /// The Jellyfin fields of the add-playlist form. A `Section`, so it composes
    /// into `LoginView`'s `Form` the same way the inline source sections do.
    struct JellyfinLoginSection: View {
        @Binding var name: String
        @Binding var serverURL: String
        @Binding var username: String
        @Binding var password: String

        var body: some View {
            Section {
                TextField("e.g. My Jellyfin Server", text: $name)
                    .textContentType(.name)

                TextField("e.g. http://192.168.1.10:8096", text: $serverURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.URL)

                TextField("Username", text: $username)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.username)

                SecureField("Password", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Jellyfin Server")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enter the server's base address — the same URL you open in a browser.")
                    Text("Movies and TV-show libraries are imported; music and photo libraries are skipped.")
                    Text("The first connection asks permission to find devices on your local network. If you decline it, only the system Settings app can allow it again.")
                }
            }
        }
    }
#endif

#if os(tvOS)
    /// The tvOS counterpart: bare labelled fields, since the tvOS form has no
    /// `Section` chrome and supplies its own name field.
    struct JellyfinLoginFields: View {
        @Binding var serverURL: String
        @Binding var username: String
        @Binding var password: String

        var body: some View {
            TVSettingsField(title: "Server URL", placeholder: "e.g. http://192.168.1.10:8096", text: $serverURL, contentType: .URL)
            TVSettingsField(title: "Username", placeholder: "Username", text: $username, contentType: .username)
            TVSettingsField(title: "Password", placeholder: "Password", text: $password, isSecure: true, contentType: .password)
        }
    }
#endif

// MARK: - Add playlist

extension LoginView {
    func addJellyfinPlaylist() {
        isLoading = true
        errorMessage = nil

        let playlistName = trimmedName.isEmpty ? "My Playlist" : trimmedName
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = JellyfinAddCheck.Input(url: jellyfinURL, username: user, password: password)

        Task {
            do {
                try await withConnectionTimeout {
                    let verified = try await JellyfinAddCheck.verify(input)
                    let playlist = Playlist(
                        name: playlistName,
                        jellyfinURL: verified.serverURL,
                        username: user,
                        password: password,
                        accessToken: verified.session.accessToken,
                        userId: verified.session.userId
                    )
                    insertAndFinish(playlist)
                }
            } catch {
                errorMessage = JellyfinAddCheck.message(for: error, input: input, timedOut: error is ConnectionTimeoutError)
                isLoading = false
            }
        }
    }
}

// MARK: - Connection test

/// The add-playlist connection test for a Jellyfin server and the copy for its
/// failures: probe the public endpoint first (wrong address vs. wrong
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
        var session: JellyfinSession
    }

    /// Returns what to store on success.
    static func verify(_ input: Input) async throws -> Verified {
        let trimmed = input.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw JellyfinError.invalidURL
        }
        let server = JellyfinClient.normalizedServerURL(url)
        let client = JellyfinClient()
        // Probe first: it answers without credentials, so a wrong host fails
        // here instead of surfacing as a login error.
        try await client.probe(server: server)
        let user = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = try await client.authenticate(server: server, username: user, password: input.password)
        return Verified(serverURL: server.absoluteString, session: session)
    }

    static func message(for error: Error, input: Input, timedOut: Bool) -> String {
        let host = URL(string: input.url.trimmingCharacters(in: .whitespacesAndNewlines))?.host
        if timedOut, isLocalHost(host) {
            return localNetworkMessage
        }
        guard let jellyfinError = error as? JellyfinError else { return error.localizedDescription }
        switch jellyfinError {
        case .unauthorized:
            return String(localized: "The server rejected this username and password.")
        case .notAJellyfinServer:
            return String(localized: "That URL doesn't answer as a Jellyfin server. Enter the server's base address, e.g. http://192.168.1.10:8096.")
        case let .networkError(underlying) where isLocalHost(host) && isUnreachable(underlying):
            return localNetworkMessage
        default:
            return jellyfinError.localizedDescription
        }
    }

    /// tvOS hint copy. One line, because the tvOS form shows a single hint
    /// under the fields.
    static var hint: LocalizedStringKey {
        "Enter the server's base address — the URL you open in a browser. A declined local network prompt can only be allowed again in Settings."
    }

    /// A declined local-network prompt is indistinguishable from an unreachable
    /// host: iOS and tvOS just fail the connection. Only the system Settings app
    /// can reverse it, and on tvOS there is no other affordance at all.
    private static var localNetworkMessage: String {
        String(localized: "Lume couldn't reach that address on your local network. If you declined the local network prompt, only the system Settings app can allow it again.")
    }

    private static func isLocalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") {
            return true
        }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") {
            return true
        }
        let parts = host.split(separator: ".")
        if parts.count == 4, parts[0] == "172", let block = Int(parts[1]), (16 ... 31).contains(block) {
            return true
        }
        return false
    }

    private static func isUnreachable(_ error: Error) -> Bool {
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

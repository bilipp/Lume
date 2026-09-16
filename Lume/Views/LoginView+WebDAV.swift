//
//  LoginView+WebDAV.swift
//  Lume
//
//  The WebDAV half of the add-playlist form: the fields, the connection test
//  and the copy that tells its four failure modes apart.
//

import SwiftUI

// MARK: - Fields

#if !os(tvOS)
    /// The WebDAV fields of the add-playlist form. A `Section`, so it composes
    /// into `LoginView`'s `Form` the same way the inline source sections do.
    struct WebDAVLoginSection: View {
        @Binding var name: String
        @Binding var shareURL: String
        @Binding var username: String
        @Binding var password: String

        var body: some View {
            Section {
                TextField("e.g. My Media Server", text: $name)
                    .textContentType(.name)

                TextField("e.g. http://192.168.1.10:8080/Movies/", text: $shareURL)
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
                Text("WebDAV Share")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enter the full URL of the folder that holds your media — a server's root address usually isn't browsable.")
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
    struct WebDAVLoginFields: View {
        @Binding var shareURL: String
        @Binding var username: String
        @Binding var password: String

        var body: some View {
            TVSettingsField(title: "Share URL", placeholder: "e.g. http://192.168.1.10:8080/Movies/", text: $shareURL, contentType: .URL)
            TVSettingsField(title: "Username (optional)", placeholder: "Username", text: $username, contentType: .username)
            TVSettingsField(title: "Password (optional)", placeholder: "Password", text: $password, isSecure: true, contentType: .password)
        }
    }
#endif

// MARK: - Add playlist

extension LoginView {
    func addWebDAVPlaylist() {
        isLoading = true
        errorMessage = nil

        let playlistName = trimmedName.isEmpty ? "My Playlist" : trimmedName
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = WebDAVAddCheck.Input(url: webdavURL, username: user, password: password)

        Task {
            do {
                try await withConnectionTimeout {
                    let url = try await WebDAVAddCheck.verify(input)
                    // An anonymous share stores no password: a stray one would
                    // be sent as a Basic header the server never asked for.
                    let playlist = Playlist(
                        name: playlistName,
                        webdavURL: url,
                        username: user,
                        password: user.isEmpty ? "" : password
                    )
                    insertAndFinish(playlist)
                }
            } catch {
                errorMessage = WebDAVAddCheck.message(for: error, input: input, timedOut: error is ConnectionTimeoutError)
                isLoading = false
            }
        }
    }
}

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

    /// Returns the URL to store on success.
    static func verify(_ input: Input) async throws -> String {
        let trimmed = input.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.host != nil else { throw WebDAVError.invalidURL }

        let user = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = user.isEmpty ? nil : WebDAVCredentials(username: user, password: input.password)
        let client = WebDAVClient()
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
        if timedOut, isLocalHost(host) { return localNetworkMessage }
        if error is AddError { return emptyShareMessage }
        guard let webdavError = error as? WebDAVError else { return error.localizedDescription }
        switch webdavError {
        case .unauthorized:
            return String(localized: "The server rejected this username and password. Leave both empty if the share allows anonymous access.")
        case .notAWebDAVServer:
            return String(localized: "That URL doesn't answer as a WebDAV share. Enter the full path of the shared folder, not just the server address.")
        case let .networkError(underlying) where isLocalHost(host) && isUnreachable(underlying):
            return localNetworkMessage
        default:
            return webdavError.localizedDescription
        }
    }

    /// tvOS hint copy. One line, because the tvOS form shows a single hint
    /// under the fields — and it is the only place a tvOS user is told about
    /// the local-network permission, which nothing in the app can re-request.
    static var hint: LocalizedStringKey {
        "Enter the full folder URL — a server's root address isn't browsable. Username and password are optional. A declined local network prompt can only be allowed again in Settings."
    }

    private static var emptyShareMessage: String {
        String(localized: "That folder is empty. Enter the full path of the folder that holds your media — a server's root address usually lists nothing.")
    }

    /// A declined local-network prompt is indistinguishable from an unreachable
    /// host: iOS and tvOS just fail the connection. Only the system Settings app
    /// can reverse it, and on tvOS there is no other affordance at all.
    private static var localNetworkMessage: String {
        String(localized: "Lume couldn't reach that address on your local network. If you declined the local network prompt, only the system Settings app can allow it again.")
    }

    private static func isLocalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
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

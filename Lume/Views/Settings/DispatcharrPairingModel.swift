//
//  DispatcharrPairingModel.swift
//  Lume
//
//  The form state behind signing in to a Dispatcharr server: its address and
//  either an API key the user generated there or a username and password.
//  Signing in replaces any other paired recording server.
//

import Foundation
import Observation

@MainActor
@Observable
final class DispatcharrPairingModel {
    enum SignInMethod: Hashable, CaseIterable {
        case apiKey
        case login
    }

    var address: String
    var method: SignInMethod
    var apiKey = ""
    var username: String
    var password = ""
    private(set) var isConnecting = false
    private(set) var errorMessage: String?

    /// `server` prefills the address, and the username of a password sign-in,
    /// for signing in to it again. Secrets are never prefilled.
    init(server: RecordingServerConfig? = nil) {
        let credential = server?.endpoint?.dispatcharrCredential
        address = server?.endpoint.map { Self.displayAddress($0.baseURL) } ?? ""
        if case let .login(username, _) = credential {
            method = .login
            self.username = username
        } else {
            method = .apiKey
            username = ""
        }
    }

    var credential: DispatcharrCredential? {
        let credential: DispatcharrCredential = switch method {
        case .apiKey:
            .apiKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        case .login:
            .login(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        }
        return credential.isComplete ? credential : nil
    }

    var hasInput: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && credential != nil
    }

    var canConnect: Bool {
        hasInput && !isConnecting
    }

    func inputDidChange() {
        errorMessage = nil
    }

    /// `true` once the server is stored. Never retried: Dispatcharr allows
    /// three sign-in attempts a minute.
    func connect() async -> Bool {
        guard canConnect else { return false }
        errorMessage = nil
        guard let baseURL = RecordingServerKind.dispatcharr.normalizedBaseURL(from: address) else {
            errorMessage = RecordingServerError.invalidAddress(.dispatcharr).localizedDescription
            return false
        }
        guard let credential else { return false }
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await RecordingServerStore.shared.pairDispatcharr(baseURL: baseURL, credential: credential)
            return true
        } catch {
            // The password stays: clearing it would clear this message through
            // the field's change handler, and a typo is as likely in the username.
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// `host:port` for a plain-http address, the way the user typed it.
    private static func displayAddress(_ baseURL: URL) -> String {
        guard baseURL.scheme == "http", let rawHost = baseURL.host(percentEncoded: false) else {
            return baseURL.absoluteString
        }
        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        return baseURL.port.map { "\(host):\($0)" } ?? host
    }
}

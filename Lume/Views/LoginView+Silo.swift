//
//  LoginView+Silo.swift
//  Lume
//
//  The Silo connection test. Silo serves third-party clients through a
//  Jellyfin-compatible service on its own port, and Lume syncs and plays a
//  Silo playlist through that service. The user enters the address they open
//  Silo at; this signs in to Silo's own API just long enough to ask where the
//  compatible service listens, then logs in there with the same credentials.
//

import Foundation

enum SiloAddCheck {
    struct Input: Hashable {
        var url: String
        var username: String
        var password: String
    }

    /// `urlSession` is a test seam (see `MediaServerAddCheck.verify`);
    /// production callers leave it `nil`.
    static func verify(_ input: Input, urlSession: URLSession? = nil) async throws -> JellyfinAddCheck.Verified {
        let trimmed = input.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw SiloError.invalidURL
        }
        let server = JellyfinClient.normalizedServerURL(url)
        let silo = SiloClient(urlSession: urlSession)
        let user = input.username.trimmingCharacters(in: .whitespacesAndNewlines)

        let token = try await silo.login(server: server, username: user, password: input.password)
        let info: SiloCompatInfo
        do {
            info = try await silo.compatInfo(server: server, token: token)
        } catch {
            await silo.logout(server: server, token: token)
            throw error
        }
        await silo.logout(server: server, token: token)

        guard info.enabled else { throw SiloError.compatDisabled }
        guard !info.pendingRestart else { throw SiloError.compatPendingRestart }

        let jellyfin = JellyfinClient(urlSession: urlSession)
        for candidate in SiloClient.compatCandidates(publicURL: info.publicURL, entered: server) {
            do {
                _ = try await jellyfin.probe(server: candidate)
            } catch is JellyfinError {
                continue
            }
            let session = try await jellyfin.authenticate(server: candidate, username: user, password: input.password)
            return JellyfinAddCheck.Verified(serverURL: candidate.absoluteString, flavor: .silo, session: session)
        }
        throw SiloError.compatUnreachable
    }

    static func message(for error: Error, input: Input, timedOut: Bool) -> String {
        let host = URL(string: input.url.trimmingCharacters(in: .whitespacesAndNewlines))?.host
        if timedOut, ServerAddressHelp.isLocalHost(host) {
            return ServerAddressHelp.localNetworkMessage
        }
        if case let .networkError(underlying) = error as? SiloError,
           ServerAddressHelp.isLocalHost(host), ServerAddressHelp.isUnreachable(underlying)
        {
            return ServerAddressHelp.localNetworkMessage
        }
        // The compat login runs on `JellyfinClient`, so its failures arrive
        // as Jellyfin errors.
        if error is JellyfinError {
            return JellyfinAddCheck.message(
                for: error,
                input: .init(url: input.url, username: input.username, password: input.password),
                timedOut: false
            )
        }
        return error.localizedDescription
    }
}

//
//  RecordingServerStore+Dispatcharr.swift
//  Lume
//
//  Signing in to a Dispatcharr server. There is no pairing code: the address
//  answers `/api/core/version/` without credentials, the user's API key or
//  username and password are checked by reading the account's own DVR access,
//  and the credential is stored encoded in the synced row's `token`. Removing
//  the server later only forgets it; nothing is revoked on Dispatcharr.
//

import Foundation
import os

extension RecordingServerStore {
    /// Checks the address and credential, then stores the server (synced to
    /// every device on the account) in place of any other recording server.
    /// Never retried: the login endpoint allows three attempts a minute.
    @discardableResult
    func pairDispatcharr(
        baseURL: URL,
        credential: DispatcharrCredential
    ) async throws(RecordingServerError) -> RecordingServerConfig {
        guard credential.isComplete else { throw .invalidCredentials }
        let kind = RecordingServerKind.dispatcharr
        let token = credential.token
        let backend = makeBackend(RecordingServerEndpoint(kind: kind, baseURL: baseURL, token: token))
        let identity: ServerIdentity
        let capabilities: RecordingServerCapabilities
        do {
            (identity, capabilities) = try await Self.offMain { () async throws(RecordingServerError) in
                let identity = try await backend.serverInfo()
                return try await (identity, backend.accountCapabilities())
            }
        } catch {
            let mapped = Self.signInError(error)
            Logger.recording.error("Dispatcharr sign-in failed: \(mapped.logDescription, privacy: .public)")
            throw mapped
        }
        guard let host = baseURL.host(percentEncoded: false), !host.isEmpty,
              let config = configService.savePairing(
                  serverID: identity.id,
                  name: host,
                  kind: kind,
                  baseURL: baseURL,
                  token: token,
                  deviceID: nil
              )
        else { throw .invalidResponse }
        Logger.recording.log("Signed in to a Dispatcharr server")
        await adoptPairing(config, capabilities: capabilities)
        return config
    }

    /// What the paired server's account can do: as read from the server once
    /// known, else its kind's own capabilities. `nil` when nothing usable is
    /// paired.
    var pairedCapabilities: RecordingServerCapabilities? {
        guard let kind = configService.activeServer?.kind else { return nil }
        return accountCapabilities ?? kind.capabilities
    }

    /// A rejected credential reads as wrong sign-in details here, not as a
    /// lapsed pairing.
    private nonisolated static func signInError(_ error: RecordingServerError) -> RecordingServerError {
        error == .unauthorized ? .invalidCredentials : error
    }
}

nonisolated extension RecordingServerStatus {
    /// Load figures counted from the recordings list, for a server that
    /// reports none of its own.
    init(counting recordings: [ServerRecording]) {
        self.init(
            activeRecordings: recordings.count { $0.status == .recording },
            scheduledRecordings: recordings.count { $0.status == .scheduled },
            freeDiskBytes: nil,
            totalDiskBytes: nil
        )
    }
}

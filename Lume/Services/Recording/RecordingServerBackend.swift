//
//  RecordingServerBackend.swift
//  Lume
//
//  The backend-agnostic seam the app talks to for DVR work. LumeRecorder is the
//  only implementation today (`LumeRecorderBackend`); the Kit's DTOs double as
//  the app's recording value types so there is one shape per concept.
//
//  Every method throws `RecordingServerError` only, so callers never see a
//  backend-specific error. Implementations never retry: a `POST`/`DELETE` that
//  failed in flight may still have landed, and only the caller knows whether
//  re-sending (with the same idempotency key) is safe.
//

import Foundation
import LumeRecorderKit

nonisolated protocol RecordingServerBackend: Sendable {
    var kind: RecordingServerKind { get }

    /// Unauthenticated identity check; fails with `.unsupportedAPIVersion` for a
    /// server this build cannot talk to.
    func serverInfo() async throws(RecordingServerError) -> ServerInfo

    /// Exchanges the server's one-time code for a token. A wrong or expired code
    /// fails with `.invalidPairingCode`.
    func pair(code: String, deviceName: String) async throws(RecordingServerError) -> PairResponse

    func status() async throws(RecordingServerError) -> ServerStatus

    func recordings() async throws(RecordingServerError) -> [Recording]

    /// Creates a record-now (`start` ≤ now) or scheduled recording. Pass a fresh
    /// key per user action; re-sending the same key returns the first result.
    func createRecording(
        _ request: CreateRecordingRequest,
        idempotencyKey: String
    ) async throws(RecordingServerError) -> Recording

    /// Cancels a scheduled recording or ends a running one.
    func stopRecording(id: UUID) async throws(RecordingServerError) -> Recording

    func deleteRecording(id: UUID) async throws(RecordingServerError)

    /// A short-lived URL any engine can play without extra headers. Fails with
    /// `.notPlayableYet` before the first segment exists.
    func playbackGrant(id: UUID) async throws(RecordingServerError) -> PlaybackGrant

    /// Revokes a paired device's token on the server.
    func unpair(deviceID: UUID) async throws(RecordingServerError)
}

/// Everything needed to reach one server, snapshotted off the SwiftData row so
/// it can cross to a background task.
nonisolated struct RecordingServerEndpoint: Hashable {
    let kind: RecordingServerKind
    let baseURL: URL
    /// `nil` before pairing.
    let token: String?

    func makeBackend() -> any RecordingServerBackend {
        switch kind {
        case .lumeRecorder:
            LumeRecorderBackend(baseURL: baseURL, token: token)
        }
    }

    func withToken(_ token: String?) -> RecordingServerEndpoint {
        RecordingServerEndpoint(kind: kind, baseURL: baseURL, token: token)
    }
}

nonisolated extension RecordingServerEndpoint: CustomStringConvertible, CustomDebugStringConvertible {
    /// Kind and token presence only: the base URL is a LAN address and the token
    /// is a bearer credential, neither of which belongs in a log line.
    var description: String {
        "RecordingServerEndpoint(\(kind.rawValue), token: \(token == nil ? "none" : "<redacted>"))"
    }

    var debugDescription: String {
        description
    }
}

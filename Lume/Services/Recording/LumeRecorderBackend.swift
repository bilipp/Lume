//
//  LumeRecorderBackend.swift
//  Lume
//
//  `RecordingServerBackend` over the LumeRecorderKit client, on the shared
//  `URLSession.recordingServer`.
//

import Foundation
import LumeRecorderKit

nonisolated struct LumeRecorderBackend: RecordingServerDevicePairing {
    let client: LumeRecorderClient

    var kind: RecordingServerKind {
        .lumeRecorder
    }

    init(baseURL: URL, token: String?) {
        client = LumeRecorderClient(baseURL: baseURL, token: token, session: .recordingServer)
    }

    func serverInfo() async throws(RecordingServerError) -> ServerIdentity {
        try await ServerIdentity(run { try await client.info() })
    }

    func pair(code: String, deviceName: String) async throws(RecordingServerError) -> RecordingServerPairing {
        do {
            return try await RecordingServerPairing(client.pair(code: code, deviceName: deviceName))
        } catch LumeRecorderError.unauthorized {
            throw .invalidPairingCode
        } catch {
            throw RecordingServerError(error)
        }
    }

    func status() async throws(RecordingServerError) -> RecordingServerStatus? {
        try await RecordingServerStatus(run { try await client.status() })
    }

    func recordings() async throws(RecordingServerError) -> [ServerRecording] {
        try await run { try await client.recordings() }.map(ServerRecording.init)
    }

    func createRecording(
        _ request: RecordingCreateRequest,
        idempotencyKey: String
    ) async throws(RecordingServerError) -> ServerRecording {
        guard let kitRequest = CreateRecordingRequest(request) else { throw .invalidRequest }
        return try await ServerRecording(run { try await client.createRecording(kitRequest, idempotencyKey: idempotencyKey) })
    }

    func stopRecording(id: RecordingID) async throws(RecordingServerError) -> ServerRecording {
        let uuid = try Self.uuid(id)
        return try await ServerRecording(run { try await client.stopRecording(id: uuid) })
    }

    func deleteRecording(id: RecordingID) async throws(RecordingServerError) {
        let uuid = try Self.uuid(id)
        try await run { try await client.deleteRecording(id: uuid) }
    }

    func playback(id: RecordingID) async throws(RecordingServerError) -> RecordingPlayback {
        let uuid = try Self.uuid(id)
        return try await RecordingPlayback(run { try await client.playback(id: uuid) })
    }

    func unpair(deviceID: UUID) async throws(RecordingServerError) {
        try await run { try await client.unpair(deviceID: deviceID) }
    }

    /// An id LumeRecorder can't have minted reads as a recording it doesn't have.
    private static func uuid(_ id: RecordingID) throws(RecordingServerError) -> UUID {
        guard let uuid = id.uuid else { throw .notFound }
        return uuid
    }

    private func run<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws(RecordingServerError) -> T {
        do {
            return try await operation()
        } catch {
            throw RecordingServerError(error)
        }
    }
}

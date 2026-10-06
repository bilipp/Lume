//
//  LumeRecorderBackend.swift
//  Lume
//
//  `RecordingServerBackend` over the LumeRecorderKit client. Uses its own
//  URLSession — never XtreamClient's single-connection session, whose one slot
//  belongs to the provider.
//

import Foundation
import LumeRecorderKit

nonisolated struct LumeRecorderBackend: RecordingServerBackend {
    let client: LumeRecorderClient

    var kind: RecordingServerKind {
        .lumeRecorder
    }

    init(baseURL: URL, token: String?) {
        client = LumeRecorderClient(baseURL: baseURL, token: token, session: Self.session)
    }

    /// A LAN server answers in milliseconds or not at all, so fail fast instead of
    /// letting an unreachable host hold a UI action for the default minute.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    func serverInfo() async throws(RecordingServerError) -> ServerInfo {
        try await run { try await client.info() }
    }

    func pair(code: String, deviceName: String) async throws(RecordingServerError) -> PairResponse {
        do {
            return try await client.pair(code: code, deviceName: deviceName)
        } catch LumeRecorderError.unauthorized {
            throw .invalidPairingCode
        } catch {
            throw RecordingServerError(error)
        }
    }

    func status() async throws(RecordingServerError) -> ServerStatus {
        try await run { try await client.status() }
    }

    func recordings() async throws(RecordingServerError) -> [Recording] {
        try await run { try await client.recordings() }
    }

    func createRecording(
        _ request: CreateRecordingRequest,
        idempotencyKey: String
    ) async throws(RecordingServerError) -> Recording {
        try await run { try await client.createRecording(request, idempotencyKey: idempotencyKey) }
    }

    func stopRecording(id: UUID) async throws(RecordingServerError) -> Recording {
        try await run { try await client.stopRecording(id: id) }
    }

    func deleteRecording(id: UUID) async throws(RecordingServerError) {
        try await run { try await client.deleteRecording(id: id) }
    }

    func playbackGrant(id: UUID) async throws(RecordingServerError) -> PlaybackGrant {
        try await run { try await client.playback(id: id) }
    }

    func unpair(deviceID: UUID) async throws(RecordingServerError) {
        try await run { try await client.unpair(deviceID: deviceID) }
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

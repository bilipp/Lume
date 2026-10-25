//
//  StubRecordingServerBackend.swift
//  LumeTests
//
//  A scripted `RecordingServerBackend` for `RecordingServerStore` tests: canned
//  answers, an optional failure for every authenticated call, and a log of
//  what the store asked for.
//

import Foundation
@testable import Lume
import LumeRecorderKit
import Synchronization

final class StubRecordingServerBackend: RecordingServerDevicePairing, RecordingServerChannelResolving {
    struct State {
        var info = ServerInfo(id: UUID(), name: "Living Room", version: "1.0.0", apiVersion: 1)
        var kind = RecordingServerKind.lumeRecorder
        var capabilities = RecordingServerCapabilities.lumeRecorder
        /// What `accountCapabilities()` answers; `capabilities` when `nil`.
        var accountCapabilities: Result<RecordingServerCapabilities, RecordingServerError>?
        var accountCapabilitiesCalls = 0
        /// Dispatcharr channel ids by stream UUID.
        var channelIDs: [UUID: Int] = [:]
        var pairResult: Result<RecordingServerPairing, RecordingServerError>?
        var recordings: [ServerRecording] = []
        var status: RecordingServerStatus? = RecordingServerStatus(
            activeRecordings: 0, scheduledRecordings: 0,
            freeDiskBytes: 1000, totalDiskBytes: 2000
        )
        /// Thrown by every call except `serverInfo` when set.
        var failure: RecordingServerError?
        var created: [(request: RecordingCreateRequest, key: String)] = []
        var stopped: [RecordingID] = []
        var deleted: [RecordingID] = []
        var unpaired: [UUID] = []
        /// How long `unpair` takes to answer, for the revoke timeout.
        var unpairDelay: Duration?
        var pairCodes: [String] = []
        var deviceNames: [String] = []
        var recordingsCalls = 0
        var grantURL = URL(string: "http://192.168.1.20:8090/hls/signed/index.m3u8")!
        var playbackHeaders: [String: String] = [:]
    }

    let state = Mutex(State())

    var kind: RecordingServerKind {
        state.withLock { $0.kind }
    }

    var capabilities: RecordingServerCapabilities {
        state.withLock { $0.capabilities }
    }

    private func failIfScripted() throws(RecordingServerError) {
        if let failure = state.withLock({ $0.failure }) {
            throw failure
        }
    }

    func accountCapabilities() async throws(RecordingServerError) -> RecordingServerCapabilities {
        let result = state.withLock { state in
            state.accountCapabilitiesCalls += 1
            return state.accountCapabilities ?? .success(state.capabilities)
        }
        return try result.get()
    }

    func channelID(forStreamUUID uuid: UUID) async -> Int? {
        state.withLock { $0.channelIDs[uuid] }
    }

    func serverInfo() async throws(RecordingServerError) -> ServerIdentity {
        state.withLock { ServerIdentity($0.info) }
    }

    func pair(code: String, deviceName: String) async throws(RecordingServerError) -> RecordingServerPairing {
        let result = state.withLock { state in
            state.pairCodes.append(code)
            state.deviceNames.append(deviceName)
            return state.pairResult ?? .success(RecordingServerPairing(
                token: "token-1", deviceID: UUID(), server: ServerIdentity(state.info)
            ))
        }
        return try result.get()
    }

    func status() async throws(RecordingServerError) -> RecordingServerStatus? {
        try failIfScripted()
        return state.withLock { $0.status }
    }

    func recordings() async throws(RecordingServerError) -> [ServerRecording] {
        try failIfScripted()
        return state.withLock { state in
            state.recordingsCalls += 1
            return state.recordings
        }
    }

    func createRecording(
        _ request: RecordingCreateRequest,
        idempotencyKey: String
    ) async throws(RecordingServerError) -> ServerRecording {
        try failIfScripted()
        return state.withLock { state in
            state.created.append((request, idempotencyKey))
            let recording = ServerRecording(
                id: RecordingID(UUID()), title: request.title, channelName: request.channelName,
                channelLogoURL: request.channelLogoURL, programmeDescription: request.programmeDescription,
                sourceRef: request.sourceRef, start: request.start, end: request.end,
                status: request.start > Date() ? .scheduled : .recording, createdAt: Date()
            )
            state.recordings.append(recording)
            return recording
        }
    }

    func stopRecording(id: RecordingID) async throws(RecordingServerError) -> ServerRecording {
        try failIfScripted()
        let stopped = state.withLock { state -> ServerRecording? in
            state.stopped.append(id)
            guard let index = state.recordings.firstIndex(where: { $0.id == id }) else { return nil }
            state.recordings[index].status = .cancelled
            return state.recordings[index]
        }
        guard let stopped else { throw .notFound }
        return stopped
    }

    func deleteRecording(id: RecordingID) async throws(RecordingServerError) {
        try failIfScripted()
        state.withLock { state in
            state.deleted.append(id)
            state.recordings.removeAll { $0.id == id }
        }
    }

    func playback(id _: RecordingID) async throws(RecordingServerError) -> RecordingPlayback {
        try failIfScripted()
        return state.withLock {
            RecordingPlayback(url: $0.grantURL, httpHeaders: $0.playbackHeaders)
        }
    }

    func unpair(deviceID: UUID) async throws(RecordingServerError) {
        if let delay = state.withLock({ $0.unpairDelay }) {
            do {
                try await Task.sleep(for: delay)
            } catch {
                throw .cancelled
            }
        }
        try failIfScripted()
        state.withLock { $0.unpaired.append(deviceID) }
    }
}

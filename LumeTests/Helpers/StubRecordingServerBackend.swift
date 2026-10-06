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

final class StubRecordingServerBackend: RecordingServerBackend {
    struct State {
        var info = ServerInfo(id: UUID(), name: "Living Room", version: "1.0.0", apiVersion: 1)
        var pairResult: Result<PairResponse, RecordingServerError>?
        var recordings: [Recording] = []
        var status = ServerStatus(
            activeRecordings: 0, scheduledRecordings: 0,
            freeDiskBytes: 1000, totalDiskBytes: 2000, maxConcurrent: 2
        )
        /// Thrown by every call except `serverInfo` when set.
        var failure: RecordingServerError?
        var created: [(request: CreateRecordingRequest, key: String)] = []
        var stopped: [UUID] = []
        var deleted: [UUID] = []
        var unpaired: [UUID] = []
        /// How long `unpair` takes to answer, for the revoke timeout.
        var unpairDelay: Duration?
        var pairCodes: [String] = []
        var deviceNames: [String] = []
        var recordingsCalls = 0
        var grantURL = URL(string: "http://192.168.1.20:8090/hls/signed/index.m3u8")!
    }

    let state = Mutex(State())

    var kind: RecordingServerKind {
        .lumeRecorder
    }

    private func failIfScripted() throws(RecordingServerError) {
        if let failure = state.withLock({ $0.failure }) {
            throw failure
        }
    }

    func serverInfo() async throws(RecordingServerError) -> ServerInfo {
        state.withLock { $0.info }
    }

    func pair(code: String, deviceName: String) async throws(RecordingServerError) -> PairResponse {
        let result = state.withLock { state in
            state.pairCodes.append(code)
            state.deviceNames.append(deviceName)
            return state.pairResult ?? .success(PairResponse(token: "token-1", deviceID: UUID(), server: state.info))
        }
        return try result.get()
    }

    func status() async throws(RecordingServerError) -> ServerStatus {
        try failIfScripted()
        return state.withLock { $0.status }
    }

    func recordings() async throws(RecordingServerError) -> [Recording] {
        try failIfScripted()
        return state.withLock { state in
            state.recordingsCalls += 1
            return state.recordings
        }
    }

    func createRecording(
        _ request: CreateRecordingRequest,
        idempotencyKey: String
    ) async throws(RecordingServerError) -> Recording {
        try failIfScripted()
        return state.withLock { state in
            state.created.append((request, idempotencyKey))
            let recording = Recording(
                id: UUID(), title: request.title, channelName: request.channelName,
                channelLogoURL: request.channelLogoURL, programmeDescription: request.programmeDescription,
                sourceRef: request.sourceRef, start: request.start, end: request.end,
                status: request.start > Date() ? .scheduled : .recording, failureReason: nil,
                createdAt: Date(), startedAt: nil, finishedAt: nil, durationSeconds: nil, sizeBytes: nil
            )
            state.recordings.append(recording)
            return recording
        }
    }

    func stopRecording(id: UUID) async throws(RecordingServerError) -> Recording {
        try failIfScripted()
        let stopped = state.withLock { state -> Recording? in
            state.stopped.append(id)
            guard let index = state.recordings.firstIndex(where: { $0.id == id }) else { return nil }
            state.recordings[index].status = .cancelled
            return state.recordings[index]
        }
        guard let stopped else { throw .notFound }
        return stopped
    }

    func deleteRecording(id: UUID) async throws(RecordingServerError) {
        try failIfScripted()
        state.withLock { state in
            state.deleted.append(id)
            state.recordings.removeAll { $0.id == id }
        }
    }

    func playbackGrant(id _: UUID) async throws(RecordingServerError) -> PlaybackGrant {
        try failIfScripted()
        return state.withLock { PlaybackGrant(url: $0.grantURL, expiresAt: Date().addingTimeInterval(3600)) }
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

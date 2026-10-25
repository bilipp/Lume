//
//  LumeRecorderBackendTests.swift
//  LumeTests
//
//  What `LumeRecorderBackend` refuses before it sends anything: ids and
//  targets only another backend can have produced.
//

import Foundation
@testable import Lume
import Testing

struct LumeRecorderBackendTests {
    @Test func `an id LumeRecorder can't have minted never reaches the server`() async throws {
        // Nothing listens on port 1, so a request that went out would fail as unreachable.
        let backend = try LumeRecorderBackend(baseURL: #require(URL(string: "http://127.0.0.1:1")), token: "token")
        let foreign = RecordingID(rawValue: "dispatcharr-7")

        await #expect(throws: RecordingServerError.notFound) {
            try await backend.stopRecording(id: foreign)
        }
        await #expect(throws: RecordingServerError.notFound) {
            try await backend.deleteRecording(id: foreign)
        }
        await #expect(throws: RecordingServerError.notFound) {
            try await backend.playback(id: foreign)
        }
    }

    @Test func `a Dispatcharr channel target is refused before any request`() async throws {
        let backend = try LumeRecorderBackend(baseURL: #require(URL(string: "http://127.0.0.1:1")), token: "token")
        let request = RecordingCreateRequest(
            target: .dispatcharrChannel(7), title: "Show", start: .now, end: .now.addingTimeInterval(3600)
        )

        await #expect(throws: RecordingServerError.invalidRequest) {
            try await backend.createRecording(request, idempotencyKey: "key")
        }
    }
}

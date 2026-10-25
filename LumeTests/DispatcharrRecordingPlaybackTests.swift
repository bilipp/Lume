//
//  DispatcharrRecordingPlaybackTests.swift
//  LumeTests
//
//  `RecordingServerStore` playback and delete for a paired Dispatcharr server:
//  the backend's credential headers reach the media, and the resume point is
//  keyed under the server's namespace rather than the bare integer id. The
//  config lives in the cloud half of the profile test container (in-memory,
//  `cloudKitDatabase: .none`).
//

import Foundation
@testable import Lume
import Synchronization
import Testing

@MainActor
struct DispatcharrRecordingPlaybackTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Harness {
        let store: RecordingServerStore
        let progressDefaults: UserDefaults
        let namespace: String
    }

    private func makeHarness() throws -> Harness {
        let container = try makeProfileTestContainer()
        let configService = RecordingServerConfigService()
        configService.configure(container: container)
        let backend = StubRecordingServerBackend()
        let grantURL = try #require(URL(string: "http://192.168.1.30:9191/api/channels/recordings/42/file/"))
        backend.state.withLock {
            $0.kind = .dispatcharr
            $0.capabilities = .dispatcharr
            $0.grantURL = grantURL
            $0.playbackHeaders = ["X-API-Key": "fixture-key"]
        }
        let progressDefaults = try #require(UserDefaults(suiteName: "DispatcharrRecordingPlaybackTests-\(UUID().uuidString)"))
        let store = RecordingServerStore(
            configService: configService,
            makeBackend: { _ in backend },
            isFeatureUnlocked: { _ in true },
            now: { [now] in now },
            progressDefaults: progressDefaults
        )
        let baseURL = try #require(URL(string: "http://192.168.1.30:9191"))
        let config = try #require(configService.savePairing(
            serverID: UUID(), name: "192.168.1.30", kind: .dispatcharr, baseURL: baseURL,
            token: DispatcharrCredential.apiKey("fixture-key").token, deviceID: nil
        ))
        return try Harness(store: store, progressDefaults: progressDefaults, namespace: #require(config.progressNamespace))
    }

    @Test func `playback is header-authorised and resumes under the namespaced key`() async throws {
        let harness = try makeHarness()
        let recording = ServerRecording(
            id: RecordingID(rawValue: "42"), title: "Harbour Lights", channelName: "Bramble TV",
            start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600), status: .completed, createdAt: now
        )
        let identifier = "\(harness.namespace)-42"
        RecordingProgressStore.save(recordingID: identifier, progress: 600, duration: 3600, defaults: harness.progressDefaults)
        // A LumeRecorder-style key for the bare id must not be picked up.
        RecordingProgressStore.save(recordingID: "42", progress: 900, duration: 3600, defaults: harness.progressDefaults)

        let media = try await harness.store.playbackMedia(for: recording)

        #expect(media.contentRef == .recording(identifier))
        #expect(media.httpHeaders == ["X-API-Key": "fixture-key"])
        #expect(media.startTime == 600)
        #expect(media.unsupportedEngines == [.avPlayer, .vlcKit])
    }

    @Test func `deleting a recording drops its namespaced resume point`() async throws {
        let harness = try makeHarness()
        let identifier = "\(harness.namespace)-42"
        RecordingProgressStore.save(recordingID: identifier, progress: 600, duration: 3600, defaults: harness.progressDefaults)

        try await harness.store.delete(id: RecordingID(rawValue: "42"))

        #expect(RecordingProgressStore.position(for: identifier, defaults: harness.progressDefaults) == 0)
    }
}

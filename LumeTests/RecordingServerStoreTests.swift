//
//  RecordingServerStoreTests.swift
//  LumeTests
//
//  `RecordingServerStore` against a scripted backend
//  (`StubRecordingServerBackend`): pairing, removal, record now, schedule,
//  stop, delete, error mapping, the polling ref-count and the
//  pending-recording lookup. The config lives in the cloud half of the profile
//  test container (in-memory, `cloudKitDatabase: .none`).
//

import Foundation
@testable import Lume
import LumeRecorderKit
import Synchronization
import Testing

@MainActor
struct RecordingServerStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let baseURL = URL(string: "http://192.168.1.20:8090")!

    private struct Harness {
        let store: RecordingServerStore
        let backend: StubRecordingServerBackend
        let configService: RecordingServerConfigService
        let endpoints: EndpointLog
        let progressDefaults: UserDefaults
    }

    private final class EndpointLog: Sendable {
        private let values = Mutex<[RecordingServerEndpoint]>([])

        func append(_ endpoint: RecordingServerEndpoint) {
            values.withLock { $0.append(endpoint) }
        }

        var first: RecordingServerEndpoint? {
            values.withLock { $0.first }
        }
    }

    private func makeHarness(
        unlocked: Bool = true,
        stalkerURL: URL? = URL(string: "http://portal.example/play/1.ts?token=abc"),
        pollInterval: Duration = .seconds(60),
        revokeTimeout: Duration = .seconds(5)
    ) throws -> Harness {
        let container = try makeProfileTestContainer()
        let configService = RecordingServerConfigService()
        configService.configure(container: container)
        let backend = StubRecordingServerBackend()
        let endpoints = EndpointLog()
        let progressDefaults = try #require(UserDefaults(suiteName: "RecordingServerStoreTests-\(UUID().uuidString)"))
        let store = RecordingServerStore(
            configService: configService,
            makeBackend: { endpoint in
                endpoints.append(endpoint)
                return backend
            },
            isFeatureUnlocked: { _ in unlocked },
            resolveStalkerLink: { _, _, _ in
                guard let stalkerURL else { throw StalkerError.noStreamURL }
                return stalkerURL
            },
            now: { [now] in now },
            pendingPollInterval: pollInterval,
            idlePollInterval: pollInterval,
            revokeTimeout: revokeTimeout,
            progressDefaults: progressDefaults
        )
        return Harness(
            store: store, backend: backend, configService: configService, endpoints: endpoints,
            progressDefaults: progressDefaults
        )
    }

    private func paired(
        unlocked: Bool = true,
        stalkerURL: URL? = URL(string: "http://portal.example/play/1.ts?token=abc"),
        revokeTimeout: Duration = .seconds(5)
    ) async throws -> Harness {
        let harness = try makeHarness(unlocked: unlocked, stalkerURL: stalkerURL, revokeTimeout: revokeTimeout)
        try await harness.store.pair(baseURL: baseURL, code: "123456")
        return harness
    }

    private func xtream() -> Playlist {
        Playlist(name: "X", serverURL: "http://example.com:8080", username: "user", password: "pass")
    }

    private func stream() -> LiveStream {
        let stream = LiveStream(id: "p-live-42", streamId: 42, name: "News")
        stream.streamIcon = "http://example.com/logo.png"
        return stream
    }

    private func programme(startOffset: TimeInterval, length: TimeInterval = 3600) -> RecordingRequestPlanner.Programme {
        RecordingRequestPlanner.Programme(
            title: "Evening News",
            description: "Headlines",
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(startOffset + length)
        )
    }

    private func recording(sourceRef: String?, status: RecordingStatus, startOffset: TimeInterval = 0) -> Recording {
        Recording(
            id: UUID(), title: "Show", channelName: "News", channelLogoURL: nil, programmeDescription: nil,
            sourceRef: sourceRef, start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(startOffset + 3600), status: status,
            failureReason: nil, createdAt: now, startedAt: nil, finishedAt: nil, durationSeconds: nil, sizeBytes: nil
        )
    }

    // MARK: Pairing

    @Test func `pairing stores the config and loads the server state`() async throws {
        let harness = try makeHarness()
        harness.backend.state.withLock { $0.recordings = [recording(sourceRef: nil, status: .completed)] }

        let config = try await harness.store.pair(baseURL: baseURL, code: " 123456 ")

        #expect(harness.store.isPaired)
        #expect(harness.configService.activeServer?.id == config.id)
        #expect(config.endpoint?.token == "token-1")
        let (codes, names) = harness.backend.state.withLock { ($0.pairCodes, $0.deviceNames) }
        #expect(codes == ["123456"])
        #expect(names.first?.hasPrefix("Lume – ") == true)
        #expect(harness.endpoints.first?.token == nil)
        #expect(harness.store.recordings.count == 1)
        #expect(harness.store.reachability == .reachable)

        await harness.store.refreshStatus()
        #expect(harness.store.status?.freeDiskBytes == 1000)
    }

    @Test func `a rejected pairing code stores nothing`() async throws {
        let harness = try makeHarness()
        harness.backend.state.withLock { $0.pairResult = .failure(.invalidPairingCode) }

        await #expect(throws: RecordingServerError.invalidPairingCode) {
            try await harness.store.pair(baseURL: baseURL, code: "000000")
        }
        #expect(!harness.store.isPaired)
    }

    @Test func `removing a server revokes the device and deletes the config`() async throws {
        let harness = try await paired()
        let config = try #require(harness.configService.activeServer)

        let removal = await harness.store.removeServer(id: config.id)

        #expect(removal == .revoked)
        #expect(harness.backend.state.withLock { $0.unpaired } == [config.deviceID].compactMap(\.self))
        #expect(!harness.store.isPaired)
        #expect(harness.configService.server(id: config.id) == nil)
        #expect(harness.store.recordings.isEmpty)
    }

    @Test func `removing a server it can't reach still deletes the config`() async throws {
        let harness = try await paired()
        let config = try #require(harness.configService.activeServer)
        harness.backend.state.withLock { $0.failure = .unreachable(.cannotConnectToHost) }

        let removal = await harness.store.removeServer(id: config.id)

        #expect(removal == .revokeFailed)
        #expect(!harness.store.isPaired)
        #expect(harness.configService.server(id: config.id) == nil)
    }

    @Test func `removing a server that errors still deletes the config`() async throws {
        let harness = try await paired()
        let config = try #require(harness.configService.activeServer)
        harness.backend.state.withLock { $0.failure = .server(status: 500, code: nil) }

        #expect(await harness.store.removeServer(id: config.id) == .revokeFailed)
        #expect(!harness.store.isPaired)
    }

    @Test(arguments: [RecordingServerError.unauthorized, .notFound])
    func `removing a server whose pairing is already gone counts as revoked`(failure: RecordingServerError) async throws {
        let harness = try await paired()
        let config = try #require(harness.configService.activeServer)
        harness.backend.state.withLock { $0.failure = failure }

        let removal = await harness.store.removeServer(id: config.id)

        #expect(removal == .revoked)
        #expect(!harness.store.isPaired)
    }

    @Test func `removing a server that doesn't answer in time gives up and deletes the config`() async throws {
        let harness = try await paired(revokeTimeout: .milliseconds(50))
        let config = try #require(harness.configService.activeServer)
        harness.backend.state.withLock { $0.unpairDelay = .seconds(30) }

        let started = ContinuousClock.now
        let removal = await harness.store.removeServer(id: config.id)

        #expect(removal == .revokeFailed)
        #expect(started.duration(to: .now) < .seconds(10))
        #expect(!harness.store.isPaired)
        #expect(harness.backend.state.withLock { $0.unpaired }.isEmpty)
    }

    @Test func `forgetting a server never contacts it`() async throws {
        let harness = try await paired()
        let config = try #require(harness.configService.activeServer)

        harness.store.forget(id: config.id)

        #expect(!harness.store.isPaired)
        #expect(harness.backend.state.withLock { $0.unpaired }.isEmpty)
    }

    // MARK: Record now

    @Test func `record now runs until the airing programme ends plus post-roll`() async throws {
        let harness = try await paired()
        let airing = programme(startOffset: -600)

        let recording = try await harness.store.recordNow(stream: stream(), playlist: xtream(), programme: airing)

        let created = try #require(harness.backend.state.withLock { $0.created.first })
        #expect(created.request.start == now)
        #expect(created.request.end == airing.end.addingTimeInterval(RecordingRequestPlanner.postRoll))
        #expect(created.request.title == "Evening News")
        #expect(created.request.channelName == "News")
        #expect(created.request.programmeDescription == "Headlines")
        #expect(created.request.channelLogoURL?.absoluteString == "http://example.com/logo.png")
        #expect(created.request.streamURL.absoluteString.hasSuffix("/live/user/pass/42.m3u8"))
        #expect(UUID(uuidString: created.key) != nil)
        #expect(harness.store.recordings.contains { $0.id == recording.id })
    }

    @Test func `record now without guide data needs a duration`() async throws {
        let harness = try await paired()

        await #expect(throws: RecordingActionError.durationRequired) {
            try await harness.store.recordNow(stream: stream(), playlist: xtream(), programme: nil)
        }
        try await harness.store.recordNow(stream: stream(), playlist: xtream(), programme: nil, duration: .oneHour)

        let created = try #require(harness.backend.state.withLock { $0.created.first })
        #expect(created.request.end == now.addingTimeInterval(3600))
        #expect(created.request.title == "News")
    }

    @Test func `each action gets a fresh idempotency key`() async throws {
        let harness = try await paired()

        try await harness.store.recordNow(stream: stream(), playlist: xtream(), programme: nil, duration: .thirtyMinutes)
        try await harness.store.recordNow(stream: stream(), playlist: xtream(), programme: nil, duration: .thirtyMinutes)

        let keys = harness.backend.state.withLock { $0.created.map(\.key) }
        #expect(keys.count == 2)
        #expect(Set(keys).count == 2)
    }

    @Test func `stalker records the resolved create_link URL, never the placeholder`() async throws {
        let harness = try await paired()
        let portal = Playlist(name: "S", portalURL: "http://portal.example/c/", macAddress: "00:1A:79:00:00:01")
        let channel = stream()
        channel.directURL = "ffmpeg http://portal.example/ch/1"

        try await harness.store.recordNow(stream: channel, playlist: portal, programme: nil, duration: .oneHour)

        let url = try #require(harness.backend.state.withLock { $0.created.first?.request.streamURL })
        #expect(url.absoluteString == "http://portal.example/play/1.ts?token=abc")
        #expect(!LiveStreamURLResolver.needsTapTimeResolution(url))
    }

    @Test func `a failed create_link maps to stream unavailable`() async throws {
        let harness = try await paired(stalkerURL: nil)
        let portal = Playlist(name: "S", portalURL: "http://portal.example/c/", macAddress: "00:1A:79:00:00:01")
        let channel = stream()
        channel.directURL = "ffmpeg http://portal.example/ch/1"

        await #expect(throws: RecordingActionError.streamUnavailable) {
            try await harness.store.recordNow(stream: channel, playlist: portal, programme: nil, duration: .oneHour)
        }
        #expect(harness.backend.state.withLock { $0.created.isEmpty })
    }

    // MARK: Schedule

    @Test func `schedule pads an upcoming programme`() async throws {
        let harness = try await paired()
        let upcoming = programme(startOffset: 1800)
        let playlist = xtream()
        let channel = stream()

        try await harness.store.schedule(stream: channel, playlist: playlist, programme: upcoming)

        let created = try #require(harness.backend.state.withLock { $0.created.first })
        #expect(created.request.start == upcoming.start.addingTimeInterval(-RecordingRequestPlanner.schedulePreRoll))
        #expect(created.request.end == upcoming.end.addingTimeInterval(RecordingRequestPlanner.postRoll))
        #expect(created.request.sourceRef == RecordingSourceRef(stream: channel, playlist: playlist).rawValue)
    }

    @Test func `schedule refuses an airing programme and stalker portals`() async throws {
        let harness = try await paired()

        await #expect(throws: RecordingActionError.programmeNotUpcoming) {
            try await harness.store.schedule(stream: stream(), playlist: xtream(), programme: programme(startOffset: -60))
        }
        let portal = Playlist(name: "S", portalURL: "http://portal.example/c/", macAddress: "00:1A:79:00:00:01")
        await #expect(throws: RecordingActionError.scheduleUnsupported) {
            try await harness.store.schedule(stream: stream(), playlist: portal, programme: programme(startOffset: 1800))
        }
        #expect(harness.backend.state.withLock { $0.created.isEmpty })
    }

    // MARK: Gates

    @Test func `recording is gated on Pro, pairing and source type`() async throws {
        let locked = try await paired(unlocked: false)
        await #expect(throws: RecordingActionError.premiumRequired) {
            try await locked.store.recordNow(stream: stream(), playlist: xtream(), programme: nil, duration: .oneHour)
        }

        let unpaired = try makeHarness()
        await #expect(throws: RecordingActionError.notPaired) {
            try await unpaired.store.recordNow(stream: stream(), playlist: xtream(), programme: nil, duration: .oneHour)
        }

        let harness = try await paired()
        let webdav = Playlist(name: "W", webdavURL: "https://dav.example/media")
        await #expect(throws: RecordingActionError.unsupportedSource) {
            try await harness.store.recordNow(stream: stream(), playlist: webdav, programme: nil, duration: .oneHour)
        }
        #expect(!harness.store.supportsScheduling(webdav.sourceType))
        #expect(harness.store.supportsRecording(xtream().sourceType))
    }

    // MARK: Stop / delete

    @Test func `stop updates the recording in place`() async throws {
        let harness = try await paired()
        let recording = try await harness.store.recordNow(
            stream: stream(), playlist: xtream(), programme: nil, duration: .oneHour
        )

        try await harness.store.stop(id: recording.id)

        #expect(harness.backend.state.withLock { $0.stopped } == [recording.id])
        #expect(harness.store.recordings.first { $0.id == recording.id }?.status == .cancelled)
    }

    @Test func `delete removes the recording, and a missing one counts as deleted`() async throws {
        let harness = try await paired()
        let recording = try await harness.store.recordNow(
            stream: stream(), playlist: xtream(), programme: nil, duration: .oneHour
        )

        try await harness.store.delete(id: recording.id)
        #expect(harness.store.recordings.isEmpty)

        harness.backend.state.withLock { $0.failure = .notFound }
        try await harness.store.delete(id: UUID())
    }

    // MARK: Errors

    @Test func `server errors map and update reachability`() async throws {
        let harness = try await paired()

        harness.backend.state.withLock { $0.failure = .concurrencyLimit }
        await #expect(throws: RecordingActionError.server(.concurrencyLimit)) {
            try await harness.store.recordNow(stream: stream(), playlist: xtream(), programme: nil, duration: .oneHour)
        }
        #expect(harness.store.reachability == .reachable)

        harness.backend.state.withLock { $0.failure = .unauthorized }
        await #expect(throws: RecordingActionError.server(.unauthorized)) {
            try await harness.store.stop(id: UUID())
        }
        #expect(harness.store.reachability.needsRepairing)

        harness.backend.state.withLock { $0.failure = .unreachable(.timedOut) }
        await harness.store.refresh()
        #expect(harness.store.reachability == .unreachable(.unreachable(.timedOut)))
    }

    @Test func `action errors never log a URL or token`() {
        let errors: [RecordingActionError] = [
            .premiumRequired, .notPaired, .unsupportedSource, .scheduleUnsupported,
            .durationRequired, .programmeNotUpcoming, .streamUnavailable, .server(.unauthorized)
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(!error.logDescription.contains("http"))
        }
    }

    // MARK: Playback

    @Test func `playback media plays the grant URL as VOD from the start`() async throws {
        let harness = try await paired()
        let recording = recording(sourceRef: nil, status: .recording)

        let media = try await harness.store.playbackMedia(for: recording)

        #expect(media.url == harness.backend.state.withLock { $0.grantURL })
        #expect(media.kind == .vod)
        #expect(media.startTime == 0)
        #expect(media.id == "recording-\(recording.id.uuidString.lowercased())")
        #expect(media.subtitle == "News")
        #expect(media.contentRef == .recording(recording.id.uuidString.lowercased()))
        #expect(media.recordingTimeline?.end == recording.end)
    }

    @Test func `a finished recording resumes where this device left it`() async throws {
        let harness = try await paired()
        let recording = recording(sourceRef: nil, status: .completed)
        RecordingProgressStore.save(
            recordingID: recording.id.uuidString, progress: 600, duration: 3600, defaults: harness.progressDefaults
        )

        let media = try await harness.store.playbackMedia(for: recording)

        #expect(media.startTime == 600)
    }

    @Test func `an in-progress recording ignores a stored position`() async throws {
        let harness = try await paired()
        let recording = recording(sourceRef: nil, status: .recording)
        RecordingProgressStore.save(
            recordingID: recording.id.uuidString, progress: 600, duration: 3600, defaults: harness.progressDefaults
        )

        let media = try await harness.store.playbackMedia(for: recording)

        #expect(media.startTime == 0)
    }

    @Test func `deleting a recording drops its resume point`() async throws {
        let harness = try await paired()
        let recording = recording(sourceRef: nil, status: .completed)
        let identifier = recording.id.uuidString
        RecordingProgressStore.save(recordingID: identifier, progress: 600, duration: 3600, defaults: harness.progressDefaults)

        try await harness.store.delete(id: recording.id)

        #expect(RecordingProgressStore.position(for: identifier, defaults: harness.progressDefaults) == 0)
    }

    // MARK: Polling

    @Test func `polling is ref-counted`() async throws {
        let harness = try makeHarness(pollInterval: .milliseconds(300))
        try await harness.store.pair(baseURL: baseURL, code: "123456")
        let baseline = harness.backend.state.withLock { $0.recordingsCalls }

        harness.store.beginObserving()
        harness.store.beginObserving()
        #expect(harness.store.isPolling)

        harness.store.endObserving()
        #expect(harness.store.isPolling)

        for _ in 0 ..< 200 where harness.backend.state.withLock({ $0.recordingsCalls }) == baseline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.backend.state.withLock { $0.recordingsCalls } == baseline + 1)

        harness.store.endObserving()
        #expect(!harness.store.isPolling)
        harness.store.endObserving()
        #expect(!harness.store.isPolling)
    }

    @Test func `polling repeats on its interval`() async throws {
        let harness = try makeHarness(pollInterval: .milliseconds(20))
        try await harness.store.pair(baseURL: baseURL, code: "123456")
        let baseline = harness.backend.state.withLock { $0.recordingsCalls }

        harness.store.beginObserving()
        for _ in 0 ..< 300 where harness.backend.state.withLock({ $0.recordingsCalls }) < baseline + 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        harness.store.endObserving()

        #expect(harness.backend.state.withLock { $0.recordingsCalls } >= baseline + 3)
    }

    // MARK: Lookup

    @Test func `active recording lookup matches the channel's sourceRef and ignores later schedules`() async throws {
        let harness = try makeHarness()
        let playlist = xtream()
        let channel = stream()
        let ref = RecordingSourceRef(stream: channel, playlist: playlist)
        harness.backend.state.withLock {
            $0.recordings = [
                recording(sourceRef: ref.rawValue, status: .completed),
                // Later tonight.
                recording(sourceRef: ref.rawValue, status: .scheduled, startOffset: 3 * 3600),
                recording(sourceRef: RecordingSourceRef(playlistID: UUID(), streamID: "other").rawValue, status: .recording)
            ]
        }
        try await harness.store.pair(baseURL: baseURL, code: "123456")

        // Only a later schedule on this channel: Record stays Record.
        #expect(harness.store.activeRecording(forSourceRef: ref) == nil)
        #expect(harness.store.activeRecording(for: channel, in: playlist) == nil)

        harness.backend.state.withLock {
            $0.recordings.append(recording(sourceRef: ref.rawValue, status: .recording))
        }
        await harness.store.refresh()

        #expect(harness.store.activeRecording(forSourceRef: ref)?.status == .recording)
        #expect(harness.store.activeRecording(for: channel, in: playlist)?.status == .recording)
        #expect(harness.store.activeRecording(forSourceRef: RecordingSourceRef(playlistID: UUID(), streamID: "none")) == nil)
    }
}

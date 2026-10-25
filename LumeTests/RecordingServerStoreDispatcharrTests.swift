//
//  RecordingServerStoreDispatcharrTests.swift
//  LumeTests
//
//  `RecordingServerStore` paired with a Dispatcharr server (scripted through
//  `StubRecordingServerBackend`): which channels offer Record, the view-only
//  gate, and the channel-id targets and unpadded times it sends. The config
//  lives in the cloud half of the profile test container (in-memory,
//  `cloudKitDatabase: .none`).
//

import Foundation
@testable import Lume
import Synchronization
import Testing

@MainActor
struct RecordingServerStoreDispatcharrTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let baseURL = URL(string: "http://192.168.1.30:9191")!
    private let channelUUID = UUID(uuidString: "0B6E4C9A-3D2F-4E1A-9C8B-7A6F5E4D3C2B")!

    private struct Harness {
        let store: RecordingServerStore
        let backend: StubRecordingServerBackend
    }

    private func paired(unlocked: Bool = true) throws -> Harness {
        let container = try makeProfileTestContainer()
        let configService = RecordingServerConfigService()
        configService.configure(container: container)
        configService.savePairing(
            serverID: UUID(),
            name: "Dispatcharr",
            kind: .dispatcharr,
            baseURL: baseURL,
            token: DispatcharrCredential.apiKey("test-key").token,
            deviceID: nil
        )
        let backend = StubRecordingServerBackend()
        backend.state.withLock {
            $0.kind = .dispatcharr
            $0.capabilities = .dispatcharr
            $0.channelIDs = [channelUUID: 12]
        }
        let store = RecordingServerStore(
            configService: configService,
            makeBackend: { _ in backend },
            isFeatureUnlocked: { _ in unlocked },
            now: { [now] in now }
        )
        return Harness(store: store, backend: backend)
    }

    private func xtream(host: String = "192.168.1.30:9191") -> Playlist {
        Playlist(name: "D", serverURL: "http://\(host)", username: "viewer", password: "secret")
    }

    private func m3u() -> Playlist {
        Playlist(name: "M", m3uURL: "http://192.168.1.30:9191/output/m3u")
    }

    private func stream(directURL: String? = nil) -> LiveStream {
        let stream = LiveStream(id: "p-live-7", streamId: 7, name: "Harbour TV")
        stream.directURL = directURL
        return stream
    }

    private func programme(startOffset: TimeInterval, length: TimeInterval = 3600) -> RecordingRequestPlanner.Programme {
        RecordingRequestPlanner.Programme(
            title: "Harbour Lights",
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(startOffset + length)
        )
    }

    private func supports(_ harness: Harness, _ stream: LiveStream, _ playlist: Playlist) -> (record: Bool, schedule: Bool) {
        let source = RecordingPlaylistSource(playlist: playlist)
        return (harness.store.supportsRecording(stream, in: source), harness.store.supportsScheduling(stream, in: source))
    }

    // MARK: Availability

    @Test func `only playlists the paired server serves offer Record`() throws {
        let harness = try paired()

        #expect(supports(harness, stream(), xtream()) == (true, true))
        #expect(supports(harness, stream(), xtream(host: "192.168.1.30:8080")) == (false, false))
        #expect(supports(harness, stream(), xtream(host: "provider.example")) == (false, false))
        let portal = Playlist(name: "S", portalURL: "http://192.168.1.30:9191/c/", macAddress: "00:1A:79:00:00:01")
        #expect(supports(harness, stream(), portal) == (false, false))
    }

    @Test func `m3u channels need a URL naming one of the server's channels`() throws {
        let harness = try paired()
        let proxied = stream(directURL: "http://192.168.1.30:9191/proxy/ts/stream/\(channelUUID.uuidString.lowercased())")
        let xcStyle = stream(directURL: "http://192.168.1.30:9191/live/viewer/secret/12.ts")
        let direct = stream(directURL: "http://provider.example/live/u/p/12.ts")

        #expect(supports(harness, proxied, m3u()) == (true, true))
        #expect(supports(harness, xcStyle, m3u()) == (true, true))
        #expect(supports(harness, direct, m3u()) == (false, false))
        #expect(supports(harness, stream(), m3u()) == (false, false))
    }

    @Test func `a view-only account hides Record once its permissions are read`() async throws {
        let harness = try paired()
        var viewOnly = RecordingServerCapabilities.dispatcharr
        viewOnly.readOnly = true
        harness.backend.state.withLock { $0.accountCapabilities = .success(viewOnly) }

        #expect(supports(harness, stream(), xtream()).record)
        await harness.store.refresh()
        #expect(supports(harness, stream(), xtream()) == (false, false))

        await harness.store.refresh()
        #expect(harness.backend.state.withLock { $0.accountCapabilitiesCalls } == 1)
    }

    @Test func `a failed permissions read leaves Record on and retries`() async throws {
        let harness = try paired()
        harness.backend.state.withLock { $0.accountCapabilities = .failure(.unreachable(.timedOut)) }

        await harness.store.refresh()
        #expect(supports(harness, stream(), xtream()).record)
        await harness.store.refresh()
        #expect(harness.backend.state.withLock { $0.accountCapabilitiesCalls } == 2)
    }

    // MARK: Record

    @Test func `record now sends the channel id and the programme's own times`() async throws {
        let harness = try paired()
        let airing = programme(startOffset: -600)

        try await harness.store.recordNow(stream: stream(), playlist: xtream(), programme: airing)

        let created = try #require(harness.backend.state.withLock { $0.created.first })
        #expect(created.request.target == .dispatcharrChannel(7))
        #expect(created.request.start == airing.start)
        #expect(created.request.end == airing.end)
    }

    @Test func `schedule resolves an m3u stream uuid without padding`() async throws {
        let harness = try paired()
        let upcoming = programme(startOffset: 1800)
        let proxied = stream(directURL: "http://192.168.1.30:9191/proxy/ts/stream/\(channelUUID.uuidString)")

        try await harness.store.schedule(stream: proxied, playlist: m3u(), programme: upcoming)

        let created = try #require(harness.backend.state.withLock { $0.created.first })
        #expect(created.request.target == .dispatcharrChannel(12))
        #expect(created.request.start == upcoming.start)
        #expect(created.request.end == upcoming.end)
    }

    @Test func `an unknown stream uuid or another server's playlist records nothing`() async throws {
        let harness = try paired()
        let unknown = stream(directURL: "http://192.168.1.30:9191/proxy/ts/stream/\(UUID().uuidString)")

        await #expect(throws: RecordingActionError.streamUnavailable) {
            try await harness.store.recordNow(stream: unknown, playlist: m3u(), programme: nil, duration: .oneHour)
        }
        await #expect(throws: RecordingActionError.unsupportedSource) {
            try await harness.store.recordNow(
                stream: stream(), playlist: xtream(host: "provider.example"), programme: nil, duration: .oneHour
            )
        }
        #expect(harness.backend.state.withLock { $0.created.isEmpty })
    }

    // MARK: Record surfaces

    @Test func `the playlist gate follows the paired server's address`() throws {
        let harness = try paired()
        let endpoint = try #require(harness.store.pairedEndpoint)

        #expect(harness.store.supportsRecording(in: RecordingPlaylistSource(playlist: xtream()), on: endpoint))
        #expect(harness.store.supportsRecording(in: RecordingPlaylistSource(playlist: m3u()), on: endpoint))
        #expect(!harness.store.supportsRecording(
            in: RecordingPlaylistSource(playlist: xtream(host: "provider.example")), on: endpoint
        ))
    }

    @Test func `only a schedule the server hasn't started cancels`() throws {
        let harness = try paired()
        let opened = ServerRecording(
            id: RecordingID(rawValue: "5"), title: "Harbour Lights", start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(3600), status: .scheduled, createdAt: now
        )
        var running = opened
        running.status = .recording

        #expect(harness.store.cancelsRatherThanStops(opened))
        #expect(!harness.store.cancelsRatherThanStops(running))
        #expect(!RecordingServerCapabilities.lumeRecorder.cancelsRatherThanStops(opened, now: now))
    }
}

struct DispatcharrChannelLocatorTests {
    private let baseURL = URL(string: "http://dvr.local:9191")!

    @Test(arguments: [
        ("http://dvr.local:9191", true),
        ("HTTP://DVR.LOCAL:9191/player_api.php", true),
        ("dvr.local:9191", true),
        ("http://dvr.local", false),
        ("https://dvr.local:9191", true),
        ("http://other.local:9191", false)
    ])
    func `matches host and port`(url: String, served: Bool) {
        #expect(DispatcharrChannelLocator.isServed(url, by: baseURL) == served)
    }

    @Test func `a URL without a port uses its scheme's`() throws {
        let https = try #require(URL(string: "https://dvr.example"))
        #expect(DispatcharrChannelLocator.isServed("https://dvr.example:443/output/m3u", by: https))
        #expect(!DispatcharrChannelLocator.isServed("http://dvr.example/output/m3u", by: https))
    }

    @Test func `parses proxy and XC-style stream URLs`() {
        let uuid = UUID()
        #expect(DispatcharrChannelLocator.locator(inStreamURL: "http://dvr.local:9191/proxy/ts/stream/\(uuid.uuidString)")
            == .streamUUID(uuid))
        #expect(DispatcharrChannelLocator.locator(inStreamURL: "http://dvr.local:9191/live/u/p/42.ts") == .channelID(42))
        #expect(DispatcharrChannelLocator.locator(inStreamURL: "http://dvr.local:9191/live/u/p/42") == .channelID(42))
        #expect(DispatcharrChannelLocator.locator(inStreamURL: "http://dvr.local:9191/proxy/ts/stream/not-a-uuid") == nil)
        #expect(DispatcharrChannelLocator.locator(inStreamURL: "http://dvr.local:9191/movie/u/p/42.mkv") == nil)
    }
}

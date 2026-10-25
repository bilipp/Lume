//
//  DispatcharrBackendTests.swift
//  LumeTests
//
//  `DispatcharrBackend` against the canned 0.33.0 responses in
//  `LumeTests/Fixtures/Dispatcharr/`: status mapping, the create body, cancel
//  vs stop, playback URLs and auth, and account capabilities. Each test talks
//  to its own host so the shared stub protocol keeps suites independent.
//

import Foundation
@testable import Lume
import Testing

struct DispatcharrBackendTests {
    private static let apiKey = DispatcharrCredential.apiKey("fixture-key-0000")
    private static let login = DispatcharrCredential.login(username: "tester", password: "correct horse")
    private static let recordingsPath = "/api/channels/recordings/"
    private static let channelsPath = "/api/channels/channels/"
    private static let tokenPath = "/api/accounts/token/"
    /// Between the fixture's schedule and its running recording.
    private static let fixtureNow = Self.utc(2026, 10, 24, 18, 30)

    // MARK: - Recordings

    @Test func `recordings map every Dispatcharr status`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        let recordings = try dispatcharrFixture("dispatcharr-recordings.json")
        let channels = try dispatcharrFixture("dispatcharr-channels.json")
        StubURLProtocol.register(host: host) { request in
            .init(body: request.url?.path(percentEncoded: false) == Self.channelsPath ? channels : recordings)
        }

        let mapped = try await backend.recordings()
        let byID = Dictionary(uniqueKeysWithValues: mapped.map { ($0.id.rawValue, $0) })

        #expect(mapped.map(\.id.rawValue) == ["11", "12", "13", "14", "15", "16", "17", "18"])
        #expect(mapped.map(\.status) == [
            .scheduled, .scheduled, .recording, .completed, .completed, .failed, .failed, .failed
        ])
        #expect(mapped.map(\.isPartial) == [false, false, false, false, true, false, false, false])

        let scheduled = try #require(byID["11"])
        #expect(scheduled.title == "Harbour Lights")
        #expect(scheduled.channelName == "Bramble TV")
        #expect(scheduled.channelLogoURL?.path(percentEncoded: false) == "/api/channels/logos/2/cache/")
        #expect(scheduled.sourceRef == "xtream:7f1c2a90-3b4d-4e5f-8a6b-7c8d9e0f1a2b:2:1792958400")
        #expect(scheduled.programmeDescription == "A quiet evening on the fictional coast.")
        #expect(scheduled.start == Self.utc(2026, 10, 25, 19, 55))

        #expect(byID["12"]?.sourceRef == nil)
        #expect(byID["13"]?.startedAt != nil)
        #expect(byID["14"]?.sizeBytes == 734_003_200)
        #expect(byID["14"]?.finishedAt != nil)
        #expect(byID["15"]?.finishedAt != nil)
        #expect(byID["16"]?.failureReason == "source_unavailable")
        #expect(byID["16"]?.channelLogoURL == nil)
        #expect(byID["18"]?.status == .failed)
        #expect(byID["18"]?.failureReason == nil)
        #expect(byID["18"]?.title == "Bramble TV")
    }

    @Test(arguments: [
        (#"{"status":"stopped"}"#, ServerRecordingStatus.cancelled, false),
        (#"{"status":"stopped","started_at":"2026-10-24 09:00:00","bytes_written":10}"#, .completed, true),
        (#"{"status":"interrupted","interrupted_reason":"server_shutdown","bytes_written":4096}"#, .completed, true),
        (#"{"status":"cancelled"}"#, .cancelled, false),
        (#"{"status":"remuxing"}"#, .unknown("remuxing"), false)
    ])
    func `edge statuses map to the app's states`(properties: String, status: ServerRecordingStatus, partial: Bool) throws {
        let json = #"{"id":5,"channel":1,"start_time":"2026-10-24T09:00:00Z","end_time":"2026-10-24T10:00:00Z","custom_properties":\#(properties)}"#
        let recording = try JSONDecoder().decode(DispatcharrRecording.self, from: Data(json.utf8))

        let mapped = DispatcharrBackend.serverRecording(recording, channelName: nil, channelLogoURL: nil, now: Self.fixtureNow)

        #expect(mapped.status == status)
        #expect(mapped.isPartial == partial)
    }

    @Test func `an interrupted recording without media fails as interrupted`() throws {
        let json = #"{"id":5,"start_time":"2026-10-24T09:00:00Z","end_time":"2026-10-24T10:00:00Z","custom_properties":{"status":"interrupted","interrupted_reason":"server_shutdown"}}"#
        let recording = try JSONDecoder().decode(DispatcharrRecording.self, from: Data(json.utf8))

        let mapped = DispatcharrBackend.serverRecording(recording, channelName: nil, channelLogoURL: nil, now: Self.fixtureNow)

        #expect(mapped.status == .failed)
        #expect(mapped.failureReason == "interrupted")
        #expect(mapped.title == String(localized: "Recording"))
    }

    @Test func `status is left to the store's count`() throws {
        let (backend, _) = try makeBackend(Self.apiKey)

        #expect(!backend.capabilities.hasStatusEndpoint)
    }

    @Test func `a failed channel list leaves names out instead of failing`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        let recordings = try dispatcharrFixture("dispatcharr-recordings.json")
        StubURLProtocol.register(host: host) { request in
            request.url?.path(percentEncoded: false) == Self.channelsPath ? .init(status: 500) : .init(body: recordings)
        }

        let mapped = try await backend.recordings()
        _ = try await backend.recordings()

        #expect(mapped.count == 8)
        #expect(mapped.allSatisfy { $0.channelName == nil })
        let channelFetches = StubURLProtocol.requests(host: host).filter { $0.url?.path(percentEncoded: false) == Self.channelsPath }
        #expect(channelFetches.count == 1)
    }

    // MARK: - Create

    @Test func `create posts exact programme times with the source ref`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        let created = try dispatcharrFixture("dispatcharr-recording-created.json")
        StubURLProtocol.register(host: host) { request in
            switch (request.httpMethod, request.url?.path(percentEncoded: false)) {
            case ("POST", Self.recordingsPath): .init(status: 201, body: created)
            default: .init(body: "[]")
            }
        }
        let request = RecordingCreateRequest(
            target: .dispatcharrChannel(2),
            title: "Harbour Lights",
            channelName: "Bramble TV",
            programmeDescription: "Quiet.",
            start: Self.utc(2026, 10, 25, 20, 0),
            end: Self.utc(2026, 10, 25, 21, 0),
            sourceRef: "xtream:ref",
            programme: DateInterval(start: Self.utc(2026, 10, 25, 20, 0), end: Self.utc(2026, 10, 25, 21, 0))
        )

        let recording = try await backend.createRecording(request, idempotencyKey: "key-1")

        #expect(recording.id.rawValue == "11")
        #expect(recording.status == .scheduled)
        let post = try #require(StubURLProtocol.requests(host: host).first { $0.httpMethod == "POST" })
        let json = try jsonBody(post)
        #expect(json["channel"] as? Int == 2)
        #expect(json["start_time"] as? String == "2026-10-25T20:00:00Z")
        #expect(json["end_time"] as? String == "2026-10-25T21:00:00Z")
        let properties = try #require(json["custom_properties"] as? [String: Any])
        #expect(properties["lume_source_ref"] as? String == "xtream:ref")
        #expect(properties["lume_request_id"] as? String == "key-1")
        let program = try #require(properties["program"] as? [String: Any])
        #expect(program["title"] as? String == "Harbour Lights")
        #expect(program["description"] as? String == "Quiet.")
        #expect(program["start_time"] as? String == "2026-10-25T20:00:00Z")
        #expect(program["end_time"] as? String == "2026-10-25T21:00:00Z")
    }

    @Test func `re-sending a create that landed returns the first recording`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        let existing = #"[{"id":40,"channel":2,"start_time":"2026-10-25T19:55:00Z","end_time":"2026-10-25T21:05:00Z","custom_properties":{"lume_request_id":"key-2"}}]"#
        StubURLProtocol.register(host: host) { request in
            request.httpMethod == "POST" ? .init(status: 500) : .init(body: existing)
        }
        let request = RecordingCreateRequest(
            target: .dispatcharrChannel(2), title: "Harbour Lights",
            start: Self.utc(2026, 10, 25, 20, 0), end: Self.utc(2026, 10, 25, 21, 0)
        )

        let recording = try await backend.createRecording(request, idempotencyKey: "key-2")

        #expect(recording.id.rawValue == "40")
        #expect(!StubURLProtocol.requests(host: host).contains { $0.httpMethod == "POST" })
    }

    @Test func `a stream URL target is rejected without a request`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        StubURLProtocol.register(host: host) { _ in .init(body: "[]") }
        let request = try RecordingCreateRequest(
            target: .streamURL(#require(URL(string: "http://provider.invalid/live/1.ts"))), title: "X",
            start: Self.fixtureNow, end: Self.fixtureNow.addingTimeInterval(60)
        )

        await #expect(throws: RecordingServerError.invalidRequest) {
            try await backend.createRecording(request, idempotencyKey: "k")
        }
        #expect(StubURLProtocol.requests(host: host).isEmpty)
    }

    @Test func `a view-only account's create surfaces forbidden without a retry`() async throws {
        let (backend, host) = try makeBackend(Self.login)
        let forbidden = try dispatcharrFixture("dispatcharr-error-403.json")
        let token = try dispatcharrFixture("dispatcharr-token.json")
        StubURLProtocol.register(host: host) { request in
            switch (request.httpMethod, request.url?.path(percentEncoded: false)) {
            case (_, Self.tokenPath): .init(body: token)
            case ("POST", _): .init(status: 403, body: forbidden)
            default: .init(body: "[]")
            }
        }
        let request = RecordingCreateRequest(
            target: .dispatcharrChannel(1), title: "X",
            start: Self.fixtureNow, end: Self.fixtureNow.addingTimeInterval(60)
        )

        await #expect(throws: RecordingServerError.forbidden) {
            try await backend.createRecording(request, idempotencyKey: "k")
        }
        let posts = StubURLProtocol.requests(host: host).filter {
            $0.httpMethod == "POST" && $0.url?.path(percentEncoded: false) == Self.recordingsPath
        }
        #expect(posts.count == 1)
    }

    // MARK: - Stop / delete

    @Test func `stopping a scheduled recording cancels it with DELETE`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        let created = try dispatcharrFixture("dispatcharr-recording-created.json")
        StubURLProtocol.register(host: host) { request in
            switch request.httpMethod {
            case "DELETE": .init(status: 204)
            default: .init(body: request.url?.path(percentEncoded: false) == Self.channelsPath ? "[]" : created)
            }
        }

        let result = try await backend.stopRecording(id: RecordingID(rawValue: "11"))

        #expect(result.status == .cancelled)
        let writes = StubURLProtocol.requests(host: host).filter { $0.httpMethod != "GET" }
        #expect(writes.map(\.httpMethod) == ["DELETE"])
        #expect(writes.first?.url?.path(percentEncoded: false) == "/api/channels/recordings/11/")
    }

    @Test func `a fixed-duration record-now goes without a programme`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        let created = try dispatcharrFixture("dispatcharr-recording-created.json")
        StubURLProtocol.register(host: host) { request in
            switch (request.httpMethod, request.url?.path(percentEncoded: false)) {
            case ("POST", Self.recordingsPath): .init(status: 201, body: created)
            default: .init(body: "[]")
            }
        }
        let request = RecordingCreateRequest(
            target: .dispatcharrChannel(2),
            title: "Bramble TV",
            channelName: "Bramble TV",
            start: Self.utc(2026, 10, 25, 20, 0),
            end: Self.utc(2026, 10, 25, 20, 30),
            sourceRef: "xtream:ref"
        )

        _ = try await backend.createRecording(request, idempotencyKey: "key-2")

        let post = try #require(StubURLProtocol.requests(host: host).first { $0.httpMethod == "POST" })
        let properties = try #require(jsonBody(post)["custom_properties"] as? [String: Any])
        #expect(properties["program"] == nil)
        #expect(properties["lume_source_ref"] as? String == "xtream:ref")
    }

    @Test func `stopping a recording that already ended sends nothing`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        let finished = #"{"id":14,"channel":2,"start_time":"2026-10-23T20:00:00Z","end_time":"2026-10-23T21:00:00Z","custom_properties":{"status":"completed","bytes_written":1024}}"#
        StubURLProtocol.register(host: host) { request in
            request.url?.path(percentEncoded: false) == Self.channelsPath ? .init(body: "[]") : .init(body: finished)
        }

        let result = try await backend.stopRecording(id: RecordingID(rawValue: "14"))

        #expect(result.status == .completed)
        #expect(StubURLProtocol.requests(host: host).allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func `stopping a running recording posts stop and keeps it`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        let running = try runningRecordingJSON()
        let stopped = try dispatcharrFixture("dispatcharr-recording-stop.json")
        StubURLProtocol.register(host: host) { request in
            switch (request.httpMethod, request.url?.path(percentEncoded: false)) {
            case ("POST", "/api/channels/recordings/13/stop/"): .init(body: stopped)
            case (_, Self.channelsPath): .init(body: "[]")
            default: .init(body: running)
            }
        }

        let result = try await backend.stopRecording(id: RecordingID(rawValue: "13"))

        #expect(result.status == .completed)
        #expect(result.isPartial)
        let writes = StubURLProtocol.requests(host: host).filter { $0.httpMethod != "GET" }
        #expect(writes.map(\.httpMethod) == ["POST"])
    }

    @Test func `delete sends DELETE for the recording`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        StubURLProtocol.register(host: host) { _ in .init(status: 204) }

        try await backend.deleteRecording(id: RecordingID(rawValue: "14"))

        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path(percentEncoded: false) == "/api/channels/recordings/14/")
    }

    @Test func `an id Dispatcharr can't have minted is not found`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        StubURLProtocol.register(host: host) { _ in .init(status: 204) }

        await #expect(throws: RecordingServerError.notFound) {
            try await backend.deleteRecording(id: RecordingID(UUID()))
        }
        #expect(StubURLProtocol.requests(host: host).isEmpty)
    }

    @Test func `a missing recording maps to notFound`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        let missing = try dispatcharrFixture("dispatcharr-error-404.json")
        StubURLProtocol.register(host: host) { _ in .init(status: 404, body: missing) }

        await #expect(throws: RecordingServerError.notFound) {
            try await backend.stopRecording(id: RecordingID(rawValue: "99"))
        }
    }

    // MARK: - Playback

    @Test func `a running recording plays its HLS playlist with the API key header`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        let running = try runningRecordingJSON()
        StubURLProtocol.register(host: host) { _ in .init(body: running) }

        let playback = try await backend.playback(id: RecordingID(rawValue: "13"))

        #expect(playback.url.path(percentEncoded: false) == "/api/channels/recordings/13/hls/index.m3u8")
        #expect(playback.httpHeaders == ["X-API-Key": "fixture-key-0000"])
    }

    @Test func `a finished recording plays its file with a Bearer header in password mode`() async throws {
        let (backend, host) = try makeBackend(Self.login)
        let token = try dispatcharrFixture("dispatcharr-token.json")
        let finished = #"{"id":14,"channel":2,"start_time":"2026-10-23T20:00:00Z","end_time":"2026-10-23T21:00:00Z","custom_properties":{"status":"completed"}}"#
        StubURLProtocol.register(host: host) { request in
            request.url?.path(percentEncoded: false) == Self.tokenPath ? .init(body: token) : .init(body: finished)
        }
        let access = try #require(
            JSONSerialization.jsonObject(with: Data(token.utf8)) as? [String: String]
        )["access"]

        let playback = try await backend.playback(id: RecordingID(rawValue: "14"))

        #expect(playback.url.path(percentEncoded: false) == "/api/channels/recordings/14/file/")
        #expect(playback.url.query == nil)
        #expect(playback.httpHeaders == ["Authorization": "Bearer \(access ?? "")"])
    }

    @Test func `a scheduled recording isn't playable yet`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        let created = try dispatcharrFixture("dispatcharr-recording-created.json")
        StubURLProtocol.register(host: host) { _ in .init(body: created) }

        await #expect(throws: RecordingServerError.notPlayableYet) {
            try await backend.playback(id: RecordingID(rawValue: "11"))
        }
    }

    // MARK: - Server and account

    @Test func `server info derives a stable id per address and account`() async throws {
        let (backend, host) = try makeBackend(Self.login)
        let version = try dispatcharrFixture("dispatcharr-version.json")
        StubURLProtocol.register(host: host) { _ in .init(body: version) }

        let info = try await backend.serverInfo()

        #expect(info.version == "0.33.0")
        #expect(info.name == "Dispatcharr")
        #expect(info.id == RecordingServerIdentity.uuid(kind: .dispatcharr, host: host, port: 9191, user: "tester"))
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func `server info without a credential still reads the version`() async throws {
        let (backend, host) = try makeBackend(nil)
        let version = try dispatcharrFixture("dispatcharr-version.json")
        StubURLProtocol.register(host: host) { _ in .init(body: version) }

        #expect(try await backend.serverInfo().version == "0.33.0")
        await #expect(throws: RecordingServerError.unauthorized) {
            try await backend.recordings()
        }
    }

    @Test func `an address that isn't Dispatcharr is an unreadable response`() async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        StubURLProtocol.register(host: host) { _ in .init(status: 404, body: "<html></html>") }

        await #expect(throws: RecordingServerError.invalidResponse) {
            try await backend.serverInfo()
        }
    }

    @Test(arguments: [
        ("dispatcharr-users-me-admin.json", false),
        ("dispatcharr-users-me-dvr-manage.json", false),
        ("dispatcharr-users-me-dvr-view.json", true),
        ("dispatcharr-users-me-standard-default.json", true)
    ])
    func `account capabilities read DVR access`(fixture: String, readOnly: Bool) async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        let body = try dispatcharrFixture(fixture)
        StubURLProtocol.register(host: host) { _ in .init(body: body) }

        let capabilities = try await backend.accountCapabilities()

        #expect(capabilities.readOnly == readOnly)
        #expect(!capabilities.diskStatus)
        #expect(!capabilities.codePairing)
        #expect(!capabilities.deviceRevoke)
    }

    @Test(arguments: ["dispatcharr-users-me-dvr-none.json", "dispatcharr-users-me-streamer.json"])
    func `an account without DVR access is forbidden`(fixture: String) async throws {
        let (backend, host) = try makeBackend(Self.apiKey)
        let body = try dispatcharrFixture(fixture)
        StubURLProtocol.register(host: host) { _ in .init(body: body) }

        await #expect(throws: RecordingServerError.forbidden) {
            try await backend.accountCapabilities()
        }
    }

    @Test func `there is no device pairing to revoke`() throws {
        let (backend, _) = try makeBackend(Self.apiKey)
        let erased: any RecordingServerBackend = backend

        #expect(!(erased is any RecordingServerDevicePairing))
    }

    @Test func `the endpoint builds a Dispatcharr backend from the stored credential`() throws {
        let endpoint = try RecordingServerEndpoint(
            kind: .dispatcharr, baseURL: #require(URL(string: "http://10.0.0.2:9191")), token: Self.apiKey.token
        )

        let backend = try #require(endpoint.makeBackend() as? DispatcharrBackend)

        #expect(backend.client.credential == Self.apiKey)
        #expect(backend.capabilities == .dispatcharr)
        #expect(!String(describing: backend).contains("fixture-key-0000"))
        #expect(!String(reflecting: backend).contains("10.0.0.2"))
    }

    // MARK: - Helpers

    private func makeBackend(_ credential: DispatcharrCredential?) throws -> (DispatcharrBackend, String) {
        let host = "dispatcharr-\(UUID().uuidString.lowercased()).test"
        let backend = try DispatcharrBackend(
            baseURL: #require(URL(string: "http://\(host):9191")),
            credential: credential,
            session: StubURLProtocol.makeSession(),
            tokens: DispatcharrTokenCache(),
            channels: DispatcharrChannelDirectory(),
            now: { Self.fixtureNow }
        )
        return (backend, host)
    }

    /// Row 13 of the list fixture on its own, as `GET /recordings/13/` returns it.
    private func runningRecordingJSON() throws -> String {
        let list = try dispatcharrFixture("dispatcharr-recordings.json")
        let rows = try #require(JSONSerialization.jsonObject(with: Data(list.utf8)) as? [[String: Any]])
        let row = try #require(rows.first { $0["id"] as? Int == 13 })
        return try #require(String(data: JSONSerialization.data(withJSONObject: row), encoding: .utf8))
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }
}

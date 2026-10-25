//
//  DispatcharrClientTests.swift
//  LumeTests
//
//  `DispatcharrClient` against the canned 0.33.0 responses in
//  `LumeTests/Fixtures/Dispatcharr/`: lenient decoding, naive timestamps, auth
//  headers, the in-memory JWT session and DRF status mapping. Each test talks
//  to its own host so the shared stub protocol keeps suites independent.
//

import Foundation
@testable import Lume
import Testing

struct DispatcharrClientTests {
    private static let accessPath = "/api/accounts/token/"
    private static let refreshPath = "/api/accounts/token/refresh/"
    private static let login = DispatcharrCredential.login(username: "tester", password: "correct horse")
    private static let apiKey = DispatcharrCredential.apiKey("fixture-key-0000")

    // MARK: - Address

    @Test(arguments: [
        ("10.0.0.5", "http://10.0.0.5:9191"),
        ("  dvr.local:9000 ", "http://dvr.local:9000"),
        ("https://dvr.example.com", "https://dvr.example.com"),
        ("http://dvr.example.com/some/path", "http://dvr.example.com:9191")
    ])
    func `typed addresses normalize with the Dispatcharr default port`(input: String, expected: String) {
        #expect(RecordingServerKind.dispatcharr.normalizedBaseURL(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "ftp://dvr.local", "dvr local", "http://:9191", "http://dvr.local:70000"])
    func `implausible addresses are rejected`(input: String) {
        #expect(RecordingServerKind.dispatcharr.normalizedBaseURL(from: input) == nil)
    }

    // MARK: - Decoding

    @Test func `version needs no credentials`() async throws {
        let (client, host) = try makeClient(Self.apiKey)
        let body = try dispatcharrFixture("dispatcharr-version.json")
        StubURLProtocol.register(host: host) { _ in .init(body: body) }

        let version = try await client.version()

        #expect(version.version == "0.33.0")
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url?.path(percentEncoded: false) == "/api/core/version/")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test(arguments: [
        ("dispatcharr-users-me-admin.json", DispatcharrDVRAccess.manage),
        ("dispatcharr-users-me-dvr-manage.json", .manage),
        ("dispatcharr-users-me-dvr-view.json", .view),
        ("dispatcharr-users-me-standard-default.json", .view),
        ("dispatcharr-users-me-dvr-none.json", .none),
        ("dispatcharr-users-me-streamer.json", .none)
    ])
    func `dvr access follows the server's rules`(fixture: String, expected: DispatcharrDVRAccess) async throws {
        let (client, host) = try makeClient(Self.apiKey)
        let body = try dispatcharrFixture(fixture)
        StubURLProtocol.register(host: host) { _ in .init(body: body) }

        let user = try await client.currentUser()

        #expect(user.dvrAccess == expected)
        #expect(!user.username.isEmpty)
        #expect(!String(describing: user).contains("fixture-api-key"))
        #expect(!String(describing: user).contains("fixture-xc-password"))
    }

    @Test func `channels decode the uuid to id map`() async throws {
        let (client, host) = try makeClient(Self.apiKey)
        let body = try dispatcharrFixture("dispatcharr-channels.json")
        StubURLProtocol.register(host: host) { _ in .init(body: body) }

        let channels = try await client.channels()

        #expect(channels.map(\.id) == [1, 2, 3])
        #expect(channels[0].uuid == UUID(uuidString: "5b0f3c1e-8d2a-4c61-9a7e-2f4b6d8c1a01"))
        #expect(channels[1].name == "Bramble TV")
        #expect(channels[2].channelNumber == 2.5)
        #expect(channels[2].logoID == nil)
        #expect(StubURLProtocol.requests(host: host).first?.url?.query == nil)
    }

    @Test func `a paginated channel list decodes too`() async throws {
        let (client, host) = try makeClient(Self.apiKey)
        let body = #"{"count":1,"next":null,"previous":null,"results":[{"id":7,"name":"Delta Six","uuid":"not-a-uuid"}]}"#
        StubURLProtocol.register(host: host) { _ in .init(body: body) }

        let channels = try await client.channels()

        #expect(channels == [DispatcharrChannel(id: 7, uuid: nil, name: "Delta Six")])
    }

    @Test func `recordings decode every status leniently`() async throws {
        let (client, host) = try makeClient(Self.apiKey)
        let body = try dispatcharrFixture("dispatcharr-recordings.json")
        StubURLProtocol.register(host: host) { _ in .init(body: body) }

        let recordings = try await client.recordings()
        let byID = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })

        #expect(recordings.map(\.id) == [11, 12, 13, 14, 15, 16, 17, 18])
        #expect(recordings.map(\.properties.status) == [
            nil, "scheduled", "recording", "completed", "stopped", "interrupted", "failed", nil
        ])

        let scheduled = try #require(byID[11])
        #expect(scheduled.channelID == 2)
        #expect(scheduled.start == utc(2026, 10, 25, 19, 55))
        #expect(scheduled.properties.sourceRef == "xtream:7f1c2a90-3b4d-4e5f-8a6b-7c8d9e0f1a2b:2:1792958400")
        #expect(scheduled.properties.program?.title == "Harbour Lights")
        #expect(scheduled.properties.program?.start == utc(2026, 10, 25, 20, 0))
        #expect(scheduled.properties.program?.end == utc(2026, 10, 25, 21, 0))

        #expect(byID[12]?.properties.sourceRef == nil)
        #expect(byID[12]?.properties.program?.start == utc(2026, 10, 26, 6, 0))

        let running = try #require(byID[13])
        let startedAt = try #require(running.properties.startedAt)
        #expect(abs(startedAt.timeIntervalSince(utc(2026, 10, 24, 17, 55)) - 0.412233) < 0.001)
        #expect(running.properties.posterLogoID == 1)

        let completed = try #require(byID[14])
        #expect(completed.properties.bytesWritten == 734_003_200)
        #expect(completed.properties.remuxSuccess == true)
        #expect(completed.properties.program?.subtitle == "The Lost Trowel")
        #expect(completed.properties.posterURL?.host == "example.invalid")

        let stopped = try #require(byID[15])
        let stoppedAt = try #require(stopped.properties.stoppedAt)
        #expect(abs(stoppedAt.timeIntervalSince(utc(2026, 10, 24, 9, 21, 40)) - 0.118502) < 0.001)

        #expect(byID[16]?.properties.interruptedReason == "no_stream_data: ffmpeg_failed")
        #expect(byID[16]?.properties.bytesWritten == 0)
        #expect(byID[17]?.properties.error?.isEmpty == false)
        #expect(byID[18]?.properties == DispatcharrRecordingProperties())
    }

    @Test func `naive stamps read in the server's zone`() async throws {
        let zone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let (client, host) = try makeClient(Self.apiKey, serverTimeZone: zone)
        let body = try dispatcharrFixture("dispatcharr-recordings.json")
        StubURLProtocol.register(host: host) { _ in .init(body: body) }

        let running = try #require(try await client.recordings().first { $0.id == 13 })

        // CEST on 24 Oct 2026: naive 17:55 local is 15:55 UTC; aware times are unaffected.
        let startedAt = try #require(running.properties.startedAt)
        #expect(abs(startedAt.timeIntervalSince(utc(2026, 10, 24, 15, 55)) - 0.412233) < 0.001)
        #expect(running.start == utc(2026, 10, 24, 17, 55))
    }

    @Test func `one malformed row doesn't fail the list`() async throws {
        let (client, host) = try makeClient(Self.apiKey)
        let body = #"[{"id":"x"},{"id":"21","start_time":"2026-10-25T20:00:00Z","end_time":"2026-10-25T21:00:00Z","channel":"4","custom_properties":"oops"}]"#
        StubURLProtocol.register(host: host) { _ in .init(body: body) }

        let recordings = try await client.recordings()

        #expect(recordings.map(\.id) == [21])
        #expect(recordings.first?.channelID == 4)
        #expect(recordings.first?.properties == DispatcharrRecordingProperties())
    }

    @Test func `a non-JSON body is an invalid response`() async throws {
        let (client, host) = try makeClient(Self.apiKey)
        StubURLProtocol.register(host: host) { _ in .init(body: "<html>login</html>") }

        await #expect(throws: RecordingServerError.invalidResponse) { try await client.currentUser() }
    }

    @Test(arguments: [
        ("2026-10-25T20:00:00Z", 0.0, 0),
        ("2026-10-25T20:00:00.250Z", 0.25, 0),
        ("2026-10-25T22:00:00+02:00", 0.0, 0),
        ("2026-10-25T15:30:00-0430", 0.0, 0),
        ("2026-10-25 20:00:00.5+00:00", 0.5, 0),
        ("2026-10-25 20:00:00", 0.0, 0),
        ("2026-10-25T20:00", 0.0, 0),
        ("2026-10-25 21:00:00.000000", 0.0, 3600)
    ])
    func `timestamps parse in every shape the server writes`(raw: String, fraction: Double, naiveOffset: Int) throws {
        let zone = try #require(TimeZone(secondsFromGMT: naiveOffset))
        let parsed = try #require(DispatcharrDate.parse(raw, naiveTimeZone: zone))
        #expect(abs(parsed.timeIntervalSince(utc(2026, 10, 25, 20, 0)) - fraction) < 0.0001)
    }

    @Test(arguments: ["", "yesterday", "2026-13-01T00:00:00Z", "2026-10-25T20:00:00Q", "2026-10-25"])
    func `garbage timestamps don't parse`(raw: String) {
        #expect(DispatcharrDate.parse(raw, naiveTimeZone: .gmt) == nil)
    }

    // MARK: - Writes

    @Test func `create sends the channel, exact times and the programme`() async throws {
        let (client, host) = try makeClient(Self.apiKey)
        let body = try dispatcharrFixture("dispatcharr-recording-created.json")
        StubURLProtocol.register(host: host) { _ in .init(status: 201, body: body) }
        let request = DispatcharrRecordingCreate(
            channelID: 2,
            start: utc(2026, 10, 25, 20, 0),
            end: utc(2026, 10, 25, 21, 0),
            sourceRef: "xtream:ref",
            program: DispatcharrProgram(
                title: "Harbour Lights", description: "Quiet.", start: utc(2026, 10, 25, 20, 0), end: utc(2026, 10, 25, 21, 0)
            )
        )

        let created = try await client.createRecording(request)

        #expect(created.id == 11)
        let sent = try #require(StubURLProtocol.requests(host: host).first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path(percentEncoded: false) == "/api/channels/recordings/")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try jsonBody(sent)
        #expect(json["channel"] as? Int == 2)
        #expect(json["start_time"] as? String == "2026-10-25T20:00:00Z")
        #expect(json["end_time"] as? String == "2026-10-25T21:00:00Z")
        let properties = try #require(json["custom_properties"] as? [String: Any])
        #expect(properties["lume_source_ref"] as? String == "xtream:ref")
        let program = try #require(properties["program"] as? [String: Any])
        #expect(program["title"] as? String == "Harbour Lights")
        #expect(program["description"] as? String == "Quiet.")
        #expect(program["start_time"] as? String == "2026-10-25T20:00:00Z")
    }

    @Test func `stop posts and delete deletes`() async throws {
        let (client, host) = try makeClient(Self.apiKey)
        let stopBody = try dispatcharrFixture("dispatcharr-recording-stop.json")
        StubURLProtocol.register(host: host) { request in
            request.httpMethod == "DELETE" ? .init(status: 204) : .init(body: stopBody)
        }

        try await client.stopRecording(id: 13)
        try await client.deleteRecording(id: 12)

        let sent = StubURLProtocol.requests(host: host)
        #expect(sent.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(sent.map { $0.url?.path(percentEncoded: false) } == ["/api/channels/recordings/13/stop/", "/api/channels/recordings/12/"])
    }

    @Test(arguments: [
        (400, "dispatcharr-error-400-end-in-past.json", RecordingServerError.invalidRequest),
        (400, "dispatcharr-error-400-field.json", .invalidRequest),
        (401, "dispatcharr-error-401-bad-api-key.json", .unauthorized),
        (401, "dispatcharr-error-401-missing.json", .unauthorized),
        (403, "dispatcharr-error-403.json", .forbidden),
        (403, "dispatcharr-error-403-playback.json", .forbidden),
        (404, "dispatcharr-error-404.json", .notFound),
        (409, "dispatcharr-error-409-stop-terminal.json", .conflict(code: DispatcharrClient.recordingFinishedCode)),
        (429, "dispatcharr-error-429.json", .rateLimited),
        (429, "dispatcharr-error-429-api-key.json", .rateLimited)
    ])
    func `DRF errors map to app errors`(status: Int, fixture: String, expected: RecordingServerError) async throws {
        let (client, host) = try makeClient(Self.apiKey)
        let body = try dispatcharrFixture(fixture)
        StubURLProtocol.register(host: host) { _ in .init(status: status, body: body) }

        await #expect(throws: expected) { try await client.stopRecording(id: 1) }
        #expect(StubURLProtocol.requests(host: host).count == 1)
    }

    @Test func `a server error keeps its status but no prose`() async throws {
        let (client, host) = try makeClient(Self.apiKey)
        StubURLProtocol.register(host: host) { _ in .init(status: 502, body: "http://secret@upstream") }

        let error = await #expect(throws: RecordingServerError.self) { try await client.recordings() }

        #expect(error == .server(status: 502, code: nil))
        #expect(error?.logDescription.contains("secret") == false)
    }

    @Test func `no response at all is unreachable`() async throws {
        let session = StubURLProtocol.makeSession()
        let client = try DispatcharrClient(
            baseURL: #require(URL(string: "http://unrouted-\(UUID().uuidString.lowercased()).test:9191")),
            credential: Self.apiKey, session: session, tokens: DispatcharrTokenCache()
        )

        await #expect(throws: RecordingServerError.unreachable(.unsupportedURL)) { try await client.version() }
    }
}

extension DispatcharrClientTests {
    // MARK: - Auth

    @Test func `api key mode sends only X-API-Key`() async throws {
        let (client, host) = try makeClient(Self.apiKey)
        StubURLProtocol.register(host: host) { _ in .init(body: "[]") }

        _ = try await client.recordings()

        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "fixture-key-0000")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let playback = try await client.playbackAuthorization(validFor: 60)
        #expect(playback == DispatcharrPlaybackAuthorization(headers: ["X-API-Key": "fixture-key-0000"]))
    }

    @Test func `password mode signs in once and reuses the token`() async throws {
        let (client, host) = try makeClient(Self.login)
        let tokens = try tokenPair()
        StubURLProtocol.register(host: host) { request in
            request.url?.path(percentEncoded: false) == Self.accessPath ? .init(body: tokens.body) : .init(body: "[]")
        }

        async let first = client.recordings()
        async let second = client.recordings()
        async let third = client.channels()
        _ = try await (first, second, third)
        _ = try await client.recordings()

        let sent = StubURLProtocol.requests(host: host)
        let logins = sent.filter { $0.url?.path(percentEncoded: false) == Self.accessPath }
        #expect(logins.count == 1)
        let loginBody = try jsonBody(#require(logins.first))
        #expect(loginBody as? [String: String] == ["username": "tester", "password": "correct horse"])
        let reads = sent.filter { $0.url?.path(percentEncoded: false) != Self.accessPath }
        #expect(reads.count == 4)
        #expect(reads.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(tokens.access)" })
        #expect(reads.allSatisfy { $0.value(forHTTPHeaderField: "X-API-Key") == nil })
        let playback = try await client.playbackAuthorization(validFor: 60)
        #expect(playback.headers == ["Authorization": "Bearer \(tokens.access)"])
    }

    @Test func `an expired access token is refreshed, not signed in again`() async throws {
        let clock = TestClock()
        let (client, host) = try makeClient(Self.login, clock: clock)
        let tokens = try tokenPair(lifetime: 30 * 60)
        let refreshed = try jwt(issuedAt: 0, lifetime: 30 * 60, marker: "refreshed")
        StubURLProtocol.register(host: host) { request in
            switch request.url?.path(percentEncoded: false) {
            case Self.accessPath: .init(body: tokens.body)
            case Self.refreshPath: .init(body: #"{"access":"\#(refreshed)"}"#)
            default: .init(body: "[]")
            }
        }

        _ = try await client.recordings()
        clock.advance(by: 31 * 60)
        _ = try await client.recordings()

        let sent = StubURLProtocol.requests(host: host)
        #expect(sent.count { $0.url?.path(percentEncoded: false) == Self.accessPath } == 1)
        let refresh = try #require(sent.first { $0.url?.path(percentEncoded: false) == Self.refreshPath })
        #expect(try jsonBody(refresh) as? [String: String] == ["refresh": tokens.refresh])
        #expect(sent.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(refreshed)")
    }

    @Test func `a rejected refresh token falls back to signing in`() async throws {
        let clock = TestClock()
        let (client, host) = try makeClient(Self.login, clock: clock)
        let tokens = try tokenPair()
        let refreshRejected = try dispatcharrFixture("dispatcharr-error-401-token-invalid.json")
        StubURLProtocol.register(host: host) { request in
            switch request.url?.path(percentEncoded: false) {
            case Self.accessPath: .init(body: tokens.body)
            case Self.refreshPath: .init(status: 401, body: refreshRejected)
            default: .init(body: "[]")
            }
        }

        _ = try await client.recordings()
        clock.advance(by: 31 * 60)
        _ = try await client.recordings()

        let paths = StubURLProtocol.requests(host: host).map { $0.url?.path(percentEncoded: false) }
        #expect(paths == [Self.accessPath, "/api/channels/recordings/", Self.refreshPath, Self.accessPath, "/api/channels/recordings/"])
    }

    @Test func `a read rejected with 401 refreshes and is sent once more`() async throws {
        let (client, host) = try makeClient(Self.login)
        let tokens = try tokenPair()
        let refreshed = try jwt(issuedAt: 0, lifetime: 30 * 60, marker: "refreshed")
        let rejected = try dispatcharrFixture("dispatcharr-error-401-token-invalid.json")
        StubURLProtocol.register(host: host) { request in
            switch request.url?.path(percentEncoded: false) {
            case Self.accessPath: return .init(body: tokens.body)
            case Self.refreshPath: return .init(body: #"{"access":"\#(refreshed)"}"#)
            default:
                let stale = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(tokens.access)"
                return stale ? .init(status: 401, body: rejected) : .init(body: "[]")
            }
        }

        let recordings = try await client.recordings()

        #expect(recordings.isEmpty)
        let paths = StubURLProtocol.requests(host: host).map { $0.url?.path(percentEncoded: false) }
        #expect(paths == [Self.accessPath, "/api/channels/recordings/", Self.refreshPath, "/api/channels/recordings/"])
    }

    @Test func `a write rejected with 401 is never re-sent`() async throws {
        let (client, host) = try makeClient(Self.login)
        let tokens = try tokenPair()
        let rejected = try dispatcharrFixture("dispatcharr-error-401-token-invalid.json")
        StubURLProtocol.register(host: host) { request in
            switch request.url?.path(percentEncoded: false) {
            case Self.accessPath: .init(body: tokens.body)
            case Self.refreshPath: .init(body: #"{"access":"fresh"}"#)
            default: .init(status: 401, body: rejected)
            }
        }

        await #expect(throws: RecordingServerError.unauthorized) { try await client.stopRecording(id: 13) }
        await #expect(throws: RecordingServerError.unauthorized) { try await client.deleteRecording(id: 13) }

        let sent = StubURLProtocol.requests(host: host)
        #expect(sent.count { $0.url?.path(percentEncoded: false) == "/api/channels/recordings/13/stop/" } == 1)
        #expect(sent.count { $0.url?.path(percentEncoded: false) == "/api/channels/recordings/13/" } == 1)
        // The rejected token was dropped, so the delete went out with a refreshed one.
        #expect(sent.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test func `a rejected sign-in isn't retried by every poll`() async throws {
        let clock = TestClock()
        let (client, host) = try makeClient(Self.login, clock: clock)
        let badLogin = try dispatcharrFixture("dispatcharr-error-401-bad-login.json")
        StubURLProtocol.register(host: host) { _ in .init(status: 401, body: badLogin) }

        await #expect(throws: RecordingServerError.unauthorized) { try await client.recordings() }
        await #expect(throws: RecordingServerError.unauthorized) { try await client.recordings() }
        #expect(StubURLProtocol.requests(host: host).count == 1)

        clock.advance(by: 61)
        await #expect(throws: RecordingServerError.unauthorized) { try await client.recordings() }
        #expect(StubURLProtocol.requests(host: host).count == 2)
    }

    @Test func `a throttled sign-in surfaces as rate limited`() async throws {
        let (client, host) = try makeClient(Self.login)
        let throttled = try dispatcharrFixture("dispatcharr-error-429.json")
        StubURLProtocol.register(host: host) { _ in .init(status: 429, body: throttled) }

        await #expect(throws: RecordingServerError.rateLimited) { try await client.currentUser() }
        await #expect(throws: RecordingServerError.rateLimited) { try await client.currentUser() }
        #expect(StubURLProtocol.requests(host: host).count == 1)
    }

    @Test func `token lifetime comes from the token itself`() throws {
        #expect(try DispatcharrClient.lifetime(of: jwt(issuedAt: 1000, lifetime: 600), fallback: 1) == 600)
        let fixture = try #require(try JSONSerialization.jsonObject(
            with: Data(dispatcharrFixture("dispatcharr-token.json").utf8)
        ) as? [String: String])
        let access = try #require(fixture["access"])
        #expect(DispatcharrClient.lifetime(of: access, fallback: 42) == 42)
        #expect(DispatcharrClient.lifetime(of: "not-a-jwt", fallback: 42) == 42)
    }

    // MARK: - Playback and privacy

    @Test func `playback URLs point at the recording`() throws {
        let (client, _) = try makeClient(Self.apiKey)
        #expect(client.fileURL(id: 14).path(percentEncoded: false) == "/api/channels/recordings/14/file/")
        #expect(client.hlsURL(id: 13).path(percentEncoded: false) == "/api/channels/recordings/13/hls/index.m3u8")
        #expect(client.hlsURL(id: 13).port == 9191)
    }

    @Test func `descriptions never show the credential or address`() throws {
        let (keyClient, host) = try makeClient(Self.apiKey)
        let (loginClient, _) = try makeClient(Self.login)
        for described in [String(describing: keyClient), String(reflecting: keyClient), "\(loginClient)"] {
            #expect(!described.contains("fixture-key-0000"))
            #expect(!described.contains("correct horse"))
            #expect(!described.contains(host))
        }
    }

    // MARK: - Helpers

    private func makeClient(
        _ credential: DispatcharrCredential,
        serverTimeZone: TimeZone = .gmt,
        clock: TestClock = TestClock()
    ) throws -> (DispatcharrClient, String) {
        let host = "dispatcharr-\(UUID().uuidString.lowercased()).test"
        let client = try DispatcharrClient(
            baseURL: #require(URL(string: "http://\(host):9191")),
            credential: credential,
            serverTimeZone: serverTimeZone,
            session: StubURLProtocol.makeSession(),
            tokens: DispatcharrTokenCache(),
            now: { clock.now }
        )
        return (client, host)
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )) ?? .distantPast
    }

    private struct TokenPair {
        var access: String
        var refresh: String
        var body: String
    }

    private func tokenPair(lifetime: TimeInterval? = nil) throws -> TokenPair {
        if let lifetime {
            let access = try jwt(issuedAt: 0, lifetime: lifetime, marker: "access")
            let refresh = try jwt(issuedAt: 0, lifetime: 86400, marker: "refresh")
            return TokenPair(access: access, refresh: refresh, body: #"{"access":"\#(access)","refresh":"\#(refresh)"}"#)
        }
        let body = try dispatcharrFixture("dispatcharr-token.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
        return try TokenPair(access: #require(json["access"]), refresh: #require(json["refresh"]), body: body)
    }

    private func jwt(issuedAt: TimeInterval, lifetime: TimeInterval, marker: String = "t") throws -> String {
        func encode(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try encode(["alg": "HS256", "typ": "JWT"])
        let payload = try encode(["iat": issuedAt, "exp": issuedAt + lifetime, "jti": marker])
        return "\(header).\(payload).c2ln"
    }
}

private final nonisolated class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_792_800_000)

    var now: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date += interval }
    }
}

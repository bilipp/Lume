//
//  DispatcharrPairingTests.swift
//  LumeTests
//
//  `RecordingServerStore.pairDispatcharr` against the canned 0.33.0 responses
//  in `LumeTests/Fixtures/Dispatcharr/`, through a real `DispatcharrBackend`
//  on a stubbed session: the address probe, API-key and password sign-in, the
//  view-only gate, error mapping without retries, the stored row, one server
//  at a time, and removal without contacting the server. The config lives in
//  the cloud half of the profile test container (in-memory,
//  `cloudKitDatabase: .none`). Each test talks to its own host.
//

import Foundation
@testable import Lume
import Synchronization
import Testing

@MainActor
struct DispatcharrPairingTests {
    private static let apiKey = DispatcharrCredential.apiKey("fixture-key-0000")
    private static let login = DispatcharrCredential.login(username: "tester", password: "correct horse")
    /// Between the fixture's schedule and its running recording.
    private static let fixtureNow: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 18, minute: 30)) ?? .distantPast
    }()

    private enum Path {
        static let version = "/api/core/version/"
        static let currentUser = "/api/accounts/users/me/"
        static let token = "/api/accounts/token/"
        static let recordings = "/api/channels/recordings/"
        static let channels = "/api/channels/channels/"
    }

    private struct Harness {
        let store: RecordingServerStore
        let configService: RecordingServerConfigService
        let host: String
        let baseURL: URL
        let lumeRecorder: StubRecordingServerBackend

        var requests: [URLRequest] {
            StubURLProtocol.requests(host: host)
        }

        func requests(to path: String) -> [URLRequest] {
            requests.filter { $0.url?.path(percentEncoded: false) == path }
        }
    }

    /// `responses` answers by path; anything unlisted gets an empty list.
    private func makeHarness(_ responses: [String: StubURLProtocol.Response]) throws -> Harness {
        let host = "dispatcharr-\(UUID().uuidString.lowercased()).test"
        let baseURL = try #require(URL(string: "http://\(host):9191"))
        StubURLProtocol.register(host: host) { request in
            responses[request.url?.path(percentEncoded: false) ?? ""] ?? .init(body: "[]")
        }
        let container = try makeProfileTestContainer()
        let configService = RecordingServerConfigService()
        configService.configure(container: container)
        let session = StubURLProtocol.makeSession()
        let tokens = DispatcharrTokenCache()
        let channels = DispatcharrChannelDirectory()
        let lumeRecorder = StubRecordingServerBackend()
        let store = RecordingServerStore(
            configService: configService,
            makeBackend: { endpoint in
                switch endpoint.kind {
                case .lumeRecorder:
                    lumeRecorder
                case .dispatcharr:
                    DispatcharrBackend(
                        baseURL: endpoint.baseURL,
                        credential: endpoint.token.flatMap(DispatcharrCredential.init(token:)),
                        session: session,
                        tokens: tokens,
                        channels: channels,
                        now: { Self.fixtureNow }
                    )
                }
            },
            isFeatureUnlocked: { _ in true },
            now: { Self.fixtureNow }
        )
        return Harness(
            store: store, configService: configService, host: host, baseURL: baseURL, lumeRecorder: lumeRecorder
        )
    }

    private func fixture(_ name: String, status: Int = 200) throws -> StubURLProtocol.Response {
        try .init(status: status, body: dispatcharrFixture(name))
    }

    private func signedIn(currentUser: String = "dispatcharr-users-me-admin.json") throws -> [String: StubURLProtocol.Response] {
        try [
            Path.version: fixture("dispatcharr-version.json"),
            Path.token: fixture("dispatcharr-token.json"),
            Path.currentUser: fixture(currentUser),
            Path.recordings: fixture("dispatcharr-recordings.json"),
            Path.channels: fixture("dispatcharr-channels.json")
        ]
    }

    // MARK: - Sign-in

    @Test func `an API key signs in and stores the server`() async throws {
        let harness = try makeHarness(signedIn())

        let config = try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.apiKey)

        #expect(config.kind == .dispatcharr)
        #expect(config.name == harness.host)
        #expect(config.deviceID == nil)
        #expect(config.serverID == RecordingServerIdentity.uuid(
            kind: .dispatcharr, host: harness.host, port: 9191, user: Self.apiKey.identityUser
        ))
        #expect(config.endpoint?.token.flatMap(DispatcharrCredential.init(token:)) == Self.apiKey)
        #expect(harness.configService.activeServer?.id == config.id)

        let version = try #require(harness.requests(to: Path.version).first)
        #expect(version.value(forHTTPHeaderField: "X-API-Key") == nil)
        let userRequest = try #require(harness.requests(to: Path.currentUser).first)
        #expect(userRequest.value(forHTTPHeaderField: "X-API-Key") == "fixture-key-0000")
        #expect(harness.requests(to: Path.token).isEmpty)
        #expect(!harness.requests.contains { $0.httpMethod != "GET" })
    }

    @Test func `a password mints one token and reuses it`() async throws {
        let harness = try makeHarness(signedIn())

        try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.login)
        await harness.store.refresh()

        #expect(harness.requests(to: Path.token).count == 1)
        let authenticated = harness.requests.filter { $0.url?.path(percentEncoded: false) != Path.token }
            .compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(!authenticated.isEmpty)
        #expect(Set(authenticated).count == 1)
        #expect(authenticated.allSatisfy { $0.hasPrefix("Bearer ") })
        #expect(harness.configService.activeServer?.serverID == RecordingServerIdentity.uuid(
            kind: .dispatcharr, host: harness.host, port: 9191, user: "tester"
        ))
    }

    @Test func `pairing mirrors the recordings and counts them as the status`() async throws {
        let harness = try makeHarness(signedIn())

        try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.apiKey)

        #expect(harness.store.reachability == .reachable)
        #expect(harness.store.recordings.count == 8)
        #expect(harness.store.status == RecordingServerStatus(
            activeRecordings: 1, scheduledRecordings: 2, freeDiskBytes: nil, totalDiskBytes: nil
        ))
        #expect(harness.store.accountCapabilities?.readOnly == false)
        // Permissions were read while signing in, not again on the first reload.
        #expect(harness.requests(to: Path.currentUser).count == 1)

        let before = harness.requests.count
        await harness.store.refreshStatus()
        #expect(harness.requests.count == before)
    }

    @Test func `a view-only account pairs read-only`() async throws {
        let harness = try makeHarness(signedIn(currentUser: "dispatcharr-users-me-dvr-view.json"))

        try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.login)

        #expect(harness.store.isPaired)
        #expect(harness.store.accountCapabilities?.readOnly == true)
    }

    @Test func `the same account on the same server keeps one row`() async throws {
        let harness = try makeHarness(signedIn())

        let first = try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.apiKey)
        let second = try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.apiKey)

        #expect(first.id == second.id)
        #expect(harness.configService.servers.count == 1)
    }

    // MARK: - Failures

    @Test func `a wrong API key is a sign-in error, sent once`() async throws {
        var responses = try signedIn()
        responses[Path.currentUser] = try fixture("dispatcharr-error-401-bad-api-key.json", status: 401)
        let harness = try makeHarness(responses)

        await #expect(throws: RecordingServerError.invalidCredentials) {
            try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.apiKey)
        }

        #expect(harness.requests(to: Path.currentUser).count == 1)
        #expect(harness.configService.servers.isEmpty)
        #expect(!harness.store.isPaired)
    }

    @Test func `a wrong password is a sign-in error, sent once`() async throws {
        var responses = try signedIn()
        responses[Path.token] = try fixture("dispatcharr-error-401-bad-login.json", status: 401)
        let harness = try makeHarness(responses)

        await #expect(throws: RecordingServerError.invalidCredentials) {
            try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.login)
        }

        #expect(harness.requests(to: Path.token).count == 1)
        #expect(harness.requests(to: Path.currentUser).isEmpty)
        #expect(harness.configService.servers.isEmpty)
    }

    @Test func `the login throttle surfaces without a retry`() async throws {
        var responses = try signedIn()
        responses[Path.token] = try fixture("dispatcharr-error-429.json", status: 429)
        let harness = try makeHarness(responses)

        await #expect(throws: RecordingServerError.rateLimited) {
            try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.login)
        }
        // Asking again within the throttle window doesn't reach the server.
        await #expect(throws: RecordingServerError.rateLimited) {
            try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.login)
        }

        #expect(harness.requests(to: Path.token).count == 1)
        #expect(harness.configService.servers.isEmpty)
    }

    @Test func `an account without DVR access is refused`() async throws {
        let harness = try makeHarness(signedIn(currentUser: "dispatcharr-users-me-dvr-none.json"))

        await #expect(throws: RecordingServerError.forbidden) {
            try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.apiKey)
        }

        #expect(harness.configService.servers.isEmpty)
    }

    @Test func `an address that isn't Dispatcharr is refused before signing in`() async throws {
        var responses = try signedIn()
        responses[Path.version] = try fixture("dispatcharr-error-404.json", status: 404)
        let harness = try makeHarness(responses)

        await #expect(throws: RecordingServerError.invalidResponse) {
            try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.login)
        }

        #expect(harness.requests.map { $0.url?.path(percentEncoded: false) } == [Path.version])
        #expect(harness.configService.servers.isEmpty)
    }

    @Test func `an incomplete credential is refused without a request`() async throws {
        let harness = try makeHarness(signedIn())

        await #expect(throws: RecordingServerError.invalidCredentials) {
            try await harness.store.pairDispatcharr(
                baseURL: harness.baseURL, credential: .login(username: "tester", password: "")
            )
        }

        #expect(harness.requests.isEmpty)
    }

    // MARK: - One server at a time

    @Test func `signing in replaces a paired LumeRecorder server without revoking it`() async throws {
        let harness = try makeHarness(signedIn())
        let recorderURL = try #require(URL(string: "http://192.168.1.20:8090"))
        harness.configService.savePairing(
            serverID: UUID(),
            name: "Living Room",
            kind: .lumeRecorder,
            baseURL: recorderURL,
            token: "recorder-token",
            deviceID: UUID()
        )

        try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.apiKey)

        #expect(harness.configService.servers.map(\.kind) == [.dispatcharr])
        #expect(harness.lumeRecorder.state.withLock { $0.unpaired.isEmpty })
    }

    @Test func `removing the server only forgets it`() async throws {
        let harness = try makeHarness(signedIn())
        let config = try await harness.store.pairDispatcharr(baseURL: harness.baseURL, credential: Self.apiKey)
        let before = harness.requests.count

        let removal = await harness.store.removeServer(id: config.id)

        #expect(removal == .revoked)
        #expect(harness.requests.count == before)
        #expect(harness.configService.servers.isEmpty)
        #expect(harness.store.recordings.isEmpty)
    }
}

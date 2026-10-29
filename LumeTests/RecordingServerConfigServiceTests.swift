//
//  RecordingServerConfigServiceTests.swift
//  LumeTests
//
//  Create / update / delete of the synced recording-server config through
//  `RecordingServerConfigService`, over the cloud half of the profile test
//  container (in-memory, `cloudKitDatabase: .none`).
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct RecordingServerConfigServiceTests {
    private func makeService() throws -> (RecordingServerConfigService, ModelContext) {
        let container = try makeProfileTestContainer()
        let service = RecordingServerConfigService()
        service.configure(container: container)
        return (service, container.mainContext)
    }

    private func pair(
        _ service: RecordingServerConfigService,
        serverID: UUID = UUID(),
        token: String = "token-1",
        address: String = "http://192.168.1.20:8090"
    ) -> RecordingServerConfig? {
        service.savePairing(
            RecordingServerPairing(
                token: token,
                deviceID: UUID(),
                server: ServerIdentity(id: serverID, name: "Living Room", version: "1.0.0")
            ),
            kind: .lumeRecorder,
            baseURL: URL(string: address)!
        )
    }

    @Test func `saving a pairing creates an active config`() throws {
        let (service, context) = try makeService()
        #expect(!service.isPaired)

        let config = try #require(pair(service))

        #expect(service.isPaired)
        #expect(service.activeServer?.id == config.id)
        #expect(config.kind == .lumeRecorder)
        #expect(config.endpoint?.token == "token-1")
        #expect(config.endpoint?.baseURL.absoluteString == "http://192.168.1.20:8090")
        let rows = try context.fetch(FetchDescriptor<SyncedRecordingServer>())
        #expect(rows.count == 1)
        #expect(rows.first?.token == "token-1")
    }

    @Test func `re-pairing the same server updates its row`() throws {
        let (service, context) = try makeService()
        let serverID = UUID()
        let first = try #require(pair(service, serverID: serverID, token: "old"))

        let second = try #require(pair(service, serverID: serverID, token: "new", address: "http://192.168.1.21:8090"))

        #expect(second.id == first.id)
        #expect(second.endpoint?.token == "new")
        #expect(second.baseURL == "http://192.168.1.21:8090")
        #expect(try context.fetch(FetchDescriptor<SyncedRecordingServer>()).count == 1)
    }

    @Test func `update edits fields and disabling drops the active server`() throws {
        let (service, _) = try makeService()
        let config = try #require(pair(service))

        service.update(id: config.id, name: "Basement")
        #expect(service.server(id: config.id)?.name == "Basement")

        service.update(id: config.id, isEnabled: false)
        #expect(service.server(id: config.id)?.isEnabled == false)
        #expect(service.activeServer == nil)
    }

    @Test func `delete removes every row for the id`() throws {
        let (service, context) = try makeService()
        let config = try #require(pair(service))
        context.insert(SyncedRecordingServer(id: config.id, name: "Dup", baseURL: "http://192.168.1.20:8090"))
        try context.save()

        service.delete(id: config.id)

        #expect(service.servers.isEmpty)
        #expect(!service.isPaired)
        #expect(try context.fetch(FetchDescriptor<SyncedRecordingServer>()).isEmpty)
    }

    @Test func `unknown kind is kept but never active`() throws {
        let (service, context) = try makeService()
        let row = SyncedRecordingServer(name: "Future", baseURL: "http://10.0.0.9:8090", token: "t")
        row.kindRaw = "someFutureBackend"
        context.insert(row)
        try context.save()

        service.reload()

        #expect(service.servers.count == 1)
        #expect(service.servers.first?.kind == nil)
        #expect(service.servers.first?.endpoint == nil)
        #expect(service.activeServer == nil)
        #expect(row.kindRaw == "someFutureBackend")
    }

    @Test func `an unpaired row has no endpoint`() throws {
        let (service, context) = try makeService()
        context.insert(SyncedRecordingServer(name: "No token", baseURL: "http://10.0.0.9:8090"))
        try context.save()

        service.reload()

        #expect(service.servers.first?.endpoint == nil)
        #expect(!service.isPaired)
    }

    // MARK: - Dispatcharr

    private func pairDispatcharr(
        _ service: RecordingServerConfigService,
        credential: DispatcharrCredential = .apiKey("key-1"),
        address: String = "http://192.168.1.30:9191"
    ) -> RecordingServerConfig? {
        service.savePairing(
            serverID: RecordingServerIdentity.uuid(
                kind: .dispatcharr, host: "192.168.1.30", port: 9191, user: credential.identityUser
            ),
            name: "Dispatcharr",
            kind: .dispatcharr,
            baseURL: URL(string: address)!,
            token: credential.token,
            deviceID: nil
        )
    }

    @Test func `a Dispatcharr pairing stores the encoded credential`() throws {
        let (service, context) = try makeService()
        let credential = DispatcharrCredential.login(username: "viewer", password: "hunter2")

        let config = try #require(pairDispatcharr(service, credential: credential))

        #expect(service.activeServer?.id == config.id)
        #expect(config.kind == .dispatcharr)
        #expect(config.deviceID == nil)
        let token = try #require(config.endpoint?.token)
        #expect(DispatcharrCredential(token: token) == credential)
        let rows = try context.fetch(FetchDescriptor<SyncedRecordingServer>())
        #expect(rows.count == 1)
        #expect(rows.first?.kindRaw == "dispatcharr")
    }

    @Test func `a Dispatcharr row without a usable credential has no endpoint`() throws {
        let (service, context) = try makeService()
        let row = SyncedRecordingServer(
            kind: .dispatcharr, name: "Dispatcharr", baseURL: "http://192.168.1.30:9191", token: "plain-bearer"
        )
        context.insert(row)
        context.insert(SyncedRecordingServer(
            kind: .dispatcharr, name: "Empty key", baseURL: "http://192.168.1.31:9191",
            token: DispatcharrCredential.apiKey("").token
        ))
        try context.save()

        service.reload()

        #expect(service.servers.count == 2)
        #expect(service.servers.allSatisfy { $0.endpoint == nil })
        #expect(!service.isPaired)
    }

    @Test func `the LumeRecorder token is stored verbatim`() throws {
        let (service, context) = try makeService()
        let token = #"{"type":"apiKey","apiKey":"looks-like-json"}"#

        let config = try #require(pair(service, token: token))

        #expect(config.endpoint?.token == token)
        #expect(try context.fetch(FetchDescriptor<SyncedRecordingServer>()).first?.token == token)
    }

    @Test func `pairing Dispatcharr replaces a paired LumeRecorder server`() throws {
        let (service, context) = try makeService()
        _ = try #require(pair(service))

        let config = try #require(pairDispatcharr(service))

        #expect(service.servers.map(\.id) == [config.id])
        #expect(service.activeServer?.kind == .dispatcharr)
        #expect(try context.fetch(FetchDescriptor<SyncedRecordingServer>()).count == 1)
    }

    @Test func `pairing LumeRecorder replaces a paired Dispatcharr server`() throws {
        let (service, _) = try makeService()
        _ = try #require(pairDispatcharr(service))

        let config = try #require(pair(service))

        #expect(service.servers.map(\.id) == [config.id])
        #expect(service.activeServer?.kind == .lumeRecorder)
    }

    @Test func `signing in to Dispatcharr again updates its row`() throws {
        let (service, _) = try makeService()
        let first = try #require(pairDispatcharr(service, credential: .apiKey("key-1")))

        let second = try #require(pairDispatcharr(service, credential: .apiKey("key-1"), address: "http://192.168.1.30:9191/"))

        #expect(second.id == first.id)
        #expect(service.servers.count == 1)
    }

    @Test func `pairing keeps a row from a newer build`() throws {
        let (service, context) = try makeService()
        let future = SyncedRecordingServer(name: "Future", baseURL: "http://10.0.0.9:8090", token: "t")
        future.kindRaw = "someFutureBackend"
        context.insert(future)
        try context.save()

        _ = try #require(pairDispatcharr(service))

        #expect(service.servers.count == 2)
        #expect(service.servers.contains { $0.kindRaw == "someFutureBackend" })
    }

    // MARK: - Credential + identity

    @Test(arguments: [
        DispatcharrCredential.apiKey("abc123"),
        .login(username: "viewer", password: "p@ss \"word\"")
    ])
    func `credential round-trips through the token`(credential: DispatcharrCredential) throws {
        let decoded = try #require(DispatcharrCredential(token: credential.token))
        #expect(decoded == credential)
    }

    @Test(arguments: ["", "bearer-token", "{}", #"{"type":"oauth","apiKey":"k"}"#, #"{"type":"login","username":"u","password":""}"#])
    func `incomplete or foreign tokens are not credentials`(token: String) {
        #expect(DispatcharrCredential(token: token) == nil)
    }

    @Test func `credential descriptions never show the secret`() {
        let key = DispatcharrCredential.apiKey("super-secret-key")
        let login = DispatcharrCredential.login(username: "viewer", password: "super-secret-password")
        for credential in [key, login] {
            var dumped = ""
            dump(credential, to: &dumped)
            for text in ["\(credential)", String(reflecting: credential), dumped] {
                #expect(!text.contains("super-secret"))
                #expect(!text.contains("viewer"))
            }
        }
    }

    @Test func `the API key never becomes the identity`() {
        let credential = DispatcharrCredential.apiKey("super-secret-key")
        #expect(!credential.identityUser.contains("super-secret-key"))
        #expect(credential.identityUser.count == 64)
        #expect(DispatcharrCredential.login(username: "viewer", password: "p").identityUser == "viewer")
    }

    @Test func `server identity is deterministic and scoped`() {
        let base = RecordingServerIdentity.uuid(kind: .dispatcharr, host: "NAS.local.", port: 9191, user: "viewer")
        #expect(base == RecordingServerIdentity.uuid(kind: .dispatcharr, host: "nas.local", port: 9191, user: "viewer"))
        #expect(base != RecordingServerIdentity.uuid(kind: .dispatcharr, host: "nas.local", port: 9192, user: "viewer"))
        #expect(base != RecordingServerIdentity.uuid(kind: .dispatcharr, host: "nas.local", port: 9191, user: "other"))
        #expect(base != RecordingServerIdentity.uuid(kind: .lumeRecorder, host: "nas.local", port: 9191, user: "viewer"))
        #expect(
            RecordingServerIdentity.uuid(kind: .dispatcharr, host: "[FE80::1]", port: 9191, user: "u")
                == RecordingServerIdentity.uuid(kind: .dispatcharr, host: "fe80::1", port: 9191, user: "u")
        )
        let text = base.uuidString
        #expect(text[text.index(text.startIndex, offsetBy: 14)] == "8")
    }

    @Test func `endpoint description redacts a Dispatcharr credential`() throws {
        let endpoint = try RecordingServerEndpoint(
            kind: .dispatcharr,
            baseURL: #require(URL(string: "http://10.0.0.2:9191")),
            token: DispatcharrCredential.login(username: "viewer", password: "super-secret").token
        )
        let described = String(describing: endpoint)
        #expect(described.contains("dispatcharr"))
        #expect(!described.contains("super-secret"))
        #expect(!described.contains("viewer"))
        #expect(!String(reflecting: endpoint).contains("10.0.0.2"))
    }
}

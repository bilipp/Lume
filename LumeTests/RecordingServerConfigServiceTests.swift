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
import LumeRecorderKit
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
            PairResponse(
                token: token,
                deviceID: UUID(),
                server: ServerInfo(id: serverID, name: "Living Room", version: "1.0.0", apiVersion: 1)
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
}

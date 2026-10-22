//
//  LumeCloudContainerTests.swift
//  LumeTests
//
//  The two user-data mirrors' schemas: `SyncedBackendChoice` only in the iCloud
//  mirror, the transport bookkeeping only in the Lume Cloud mirror, and neither
//  mirror ever treated as the catalog by the history purge. Every configuration
//  is in-memory with `cloudKitDatabase: .none`.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct LumeCloudContainerTests {
    private func entityNames(_ container: ModelContainer) -> Set<String> {
        Set(container.schema.entities.map(\.name))
    }

    @Test func `the Lume Cloud mirror is local-only and carries the bookkeeping`() throws {
        let container = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
        let configuration = try #require(container.configurations.first)
        #expect(container.configurations.count == 1)
        #expect(configuration.name == ContentSyncManager.lumeCloudMirrorConfigurationName)
        #expect(configuration.cloudKitContainerIdentifier == nil)

        let names = entityNames(container)
        #expect(names.contains("LumeCloudRecordState"))
        #expect(names.contains("LumeCloudSyncMeta"))
        #expect(names.contains("SyncedPlaylist"))
        #expect(names.contains("SyncedLiveTVPreferences"))
        #expect(!names.contains("SyncedBackendChoice"))
    }

    @Test func `the iCloud mirror carries the backend choice and no bookkeeping`() throws {
        let names = try entityNames(makeICloudMirrorTestContainer(extraModels: [SyncedBackendChoice.self]))
        #expect(names.contains("SyncedBackendChoice"))
        #expect(!names.contains("LumeCloudRecordState"))
        #expect(!names.contains("LumeCloudSyncMeta"))
    }

    @Test func `history purge refuses both mirrors`() throws {
        let lumeCloud = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
        #expect(ContentSyncManager.historyPurgeIsSafe(for: lumeCloud.configurations) == false)
        let iCloud = try makeICloudMirrorTestContainer(extraModels: [SyncedBackendChoice.self])
        #expect(ContentSyncManager.historyPurgeIsSafe(for: iCloud.configurations) == false)
    }

    @Test func `a record state with an existing rid replaces it`() throws {
        let container = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.insert(LumeCloudRecordState(rid: "rid-1", logicalKey: "profile:none", type: "profile", version: 1))
        try context.save()
        context.insert(LumeCloudRecordState(
            rid: "rid-1",
            logicalKey: "profile:none",
            type: "profile",
            version: 2,
            lastSyncedPayload: Data("{}".utf8),
            isDirty: true
        ))
        try context.save()

        let states = try context.fetch(FetchDescriptor<LumeCloudRecordState>())
        #expect(states.count == 1)
        #expect(states.first?.version == 2)
        #expect(states.first?.isDirty == true)
    }

    @Test func `the sync meta and backend choice round-trip`() throws {
        let lumeCloud = try ModelContext(LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true))
        lumeCloud.insert(LumeCloudSyncMeta(nextSeq: 42, accountId: "account-fixture"))
        try lumeCloud.save()
        let meta = try #require(try lumeCloud.fetch(FetchDescriptor<LumeCloudSyncMeta>()).first)
        #expect(meta.id == LumeCloudSyncMeta.singletonID)
        #expect(meta.nextSeq == 42)

        let iCloud = try ModelContext(makeICloudMirrorTestContainer(extraModels: [SyncedBackendChoice.self]))
        let rootKey = Data(repeating: 7, count: 32)
        iCloud.insert(SyncedBackendChoice(
            backend: .lumecloud,
            serverURL: "https://cloud.example.test",
            accountId: "account-fixture",
            rootKey: rootKey
        ))
        try iCloud.save()
        let choice = try #require(try iCloud.fetch(FetchDescriptor<SyncedBackendChoice>()).first)
        #expect(choice.id == SyncedBackendChoice.singletonID)
        #expect(choice.backend == SyncedBackendChoice.Backend.lumecloud.rawValue)
        #expect(choice.rootKey == rootKey)
    }
}

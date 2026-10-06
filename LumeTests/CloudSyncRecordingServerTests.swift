//
//  CloudSyncRecordingServerTests.swift
//  LumeTests
//
//  Covers the recording-server reconcile: duplicate rows for one server
//  collapse to the newest, distinct servers are kept apart, and the config
//  survives the local-catalog integrity gate. `SyncedRecordingServer` has no
//  local counterpart, so the reconcile is a pure cloud-side dedupe.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CloudSyncRecordingServerTests {
    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "cloudsync.recording.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    @Test func `duplicate server rows collapse to the newest on reconcile`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let id = UUID()
        ctx.insert(SyncedRecordingServer(
            id: id, name: "Old", baseURL: "http://10.0.0.2:8090",
            token: "old", updatedAt: Date(timeIntervalSince1970: 1000)
        ))
        ctx.insert(SyncedRecordingServer(
            id: id, name: "New", baseURL: "http://10.0.0.2:8090",
            token: "new", updatedAt: Date(timeIntervalSince1970: 2000)
        ))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        let remaining = try ctx.fetch(FetchDescriptor<SyncedRecordingServer>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.name == "New")
        #expect(remaining.first?.token == "new")
        #expect(result.recordingServersKept == 1)
        #expect(result.recordingServersDeduped == 1)
    }

    @Test func `rows pairing the same server from two devices collapse on reconcile`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let serverID = UUID()
        ctx.insert(SyncedRecordingServer(
            name: "Phone", baseURL: "http://10.0.0.2:8090", serverID: serverID,
            deviceID: UUID(), token: "phone", updatedAt: Date(timeIntervalSince1970: 1000)
        ))
        ctx.insert(SyncedRecordingServer(
            name: "TV", baseURL: "http://10.0.0.2:8090", serverID: serverID,
            deviceID: UUID(), token: "tv", updatedAt: Date(timeIntervalSince1970: 2000)
        ))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        let remaining = try ctx.fetch(FetchDescriptor<SyncedRecordingServer>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.token == "tv")
        #expect(result.recordingServersKept == 1)
        #expect(result.recordingServersDeduped == 1)
    }

    @Test func `distinct servers are not duplicates`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        ctx.insert(SyncedRecordingServer(name: "A", baseURL: "http://10.0.0.2:8090"))
        ctx.insert(SyncedRecordingServer(name: "B", baseURL: "http://10.0.0.3:8090"))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        #expect(try ctx.fetch(FetchDescriptor<SyncedRecordingServer>()).count == 2)
        #expect(result.recordingServersKept == 2)
        #expect(result.recordingServersDeduped == 0)
    }

    @Test func `an unknown backend kind is kept, not coerced`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let server = SyncedRecordingServer(name: "Future", baseURL: "http://10.0.0.2:8090")
        server.kindRaw = "somethingNewer"
        ctx.insert(server)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await engine.reconcile()

        let remaining = try ctx.fetch(FetchDescriptor<SyncedRecordingServer>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.kindRaw == "somethingNewer")
        #expect(remaining.first?.kind == nil)
    }

    @Test func `server config survives the empty-local-store recovery`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let shadow = freshShadow()

        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        ctx.insert(playlist)
        let serverID = UUID()
        ctx.insert(SyncedRecordingServer(
            id: serverID, name: "Den", baseURL: "http://10.0.0.2:8090",
            deviceID: UUID(), token: "secret"
        ))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: shadow)
        _ = await engine.reconcile()

        ctx.delete(playlist)
        try ctx.save()

        let result = await engine.reconcile()

        #expect(result.recoveredFromEmptyLocalStore)
        let remaining = try ctx.fetch(FetchDescriptor<SyncedRecordingServer>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == serverID)
        #expect(remaining.first?.token == "secret")
        #expect(result.recordingServersKept == 1)
    }
}

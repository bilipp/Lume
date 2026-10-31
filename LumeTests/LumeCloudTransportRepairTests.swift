//
//  LumeCloudTransportRepairTests.swift
//  LumeTests
//
//  Mirror rows that vanish without a recorded deletion, and rows a writer
//  removes on purpose (`SyncMirrorDeletionLog`). A push never infers a
//  tombstone from a missing row and a pull never re-sends a record whose
//  version didn't move, so a row deleted behind the transport's back used to
//  stay gone on that device for good while the server kept it — a playlist's
//  favorites and category order, or an un-favorite that never left the device.
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Synchronization
import Testing

@MainActor
struct LumeCloudTransportRepairTests {
    private typealias Codec = LumeCloudPayloadCodec

    private let container: ModelContainer
    private let keys = LumeCloudKeys.generate()
    private let server: StubLumeCloudClient
    private let log = SyncMirrorDeletionLog()
    private let profileID = UUID(uuidString: "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
    private let playlistID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000AB01")!
    private let created = Date(timeIntervalSince1970: 1_760_000_000)

    init() throws {
        container = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
        server = StubLumeCloudClient(keys: keys)
    }

    // MARK: Helpers

    private func makeTransport() throws -> LumeCloudTransport {
        try LumeCloudTransport(
            client: server, container: container, rootKey: keys.rootKey, accountId: "acct-harbor", deletionLog: log
        )
    }

    private var channelID: String {
        "\(playlistID.uuidString)-live-7"
    }

    private func channelState() -> UserContentState {
        UserContentState(
            contentId: channelID, kind: .live, profileID: profileID,
            isFavorite: true, favoriteOrder: 0, updatedAt: created
        )
    }

    private var channelKey: String {
        channelState().lumeCloudKey
    }

    private func playlistPayload() -> LumeCloudPayload {
        Codec.payload(
            for: SyncedPlaylist(
                id: playlistID, name: "Harbor Lights", serverURL: "http://provider.example:8080",
                username: "viewer", password: "secret", sourceTypeRaw: PlaylistSourceType.xtream.rawValue,
                epgURL: nil, syncEnabled: true, updatedAt: created
            ),
            previous: nil
        )
    }

    private func profilePayload() -> LumeCloudPayload {
        Codec.payload(
            for: UserProfile(id: profileID, name: "Nova", isChild: false, createdAt: created, updatedAt: created),
            previous: nil
        )
    }

    private func rows<Model: PersistentModel>(_: Model.Type) throws -> [Model] {
        try ModelContext(container).fetch(FetchDescriptor<Model>())
    }

    private func state(for key: String) throws -> LumeCloudRecordState? {
        try rows(LumeCloudRecordState.self).first { $0.logicalKey == key }
    }

    /// Deletes every `Model` row the way a writer other than the transport
    /// would, leaving the bookkeeping that calls them synced.
    private func dropRows<Model: PersistentModel>(_: Model.Type) throws {
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<Model>()) {
            context.delete(row)
        }
        try context.save()
        #expect(try rows(Model.self).isEmpty)
    }

    // MARK: Repair

    @Test func `a row removed without a deletion comes back from its last synced payload`() async throws {
        try server.upsert(playlistPayload())
        try server.upsert(Codec.payload(for: channelState(), previous: nil))
        let transport = try makeTransport()
        try await transport.pull()
        try dropRows(UserContentState.self)

        let result = try await transport.pull()

        #expect(result.mirrorChanged)
        let restored = try #require(try rows(UserContentState.self).first)
        #expect(restored.contentId == channelID)
        #expect(restored.isFavorite)
        #expect(restored.favoriteOrder == 0)
        let state = try #require(try state(for: channelKey))
        #expect(!state.isDirty)
        #expect(!state.isDeletionPending)
        // Nothing to send: the restored row is what the server already holds.
        try await transport.push()
        #expect(server.pushes.isEmpty)
    }

    @Test func `a restored row comes back even when the pull can't reach the server`() async throws {
        try server.upsert(playlistPayload())
        try server.upsert(Codec.payload(for: channelState(), previous: nil))
        let transport = try makeTransport()
        try await transport.pull()
        try dropRows(UserContentState.self)
        server.changesError.withLock { $0 = { _ in .transport(URLError(.notConnectedToInternet)) } }

        await #expect(throws: (any Error).self) { try await transport.pull() }

        #expect(try rows(UserContentState.self).map(\.contentId) == [channelID])
    }

    @Test func `content of a playlist missing from the mirror stays removed`() async throws {
        // The engine deletes the state of a playlist gone on both sides;
        // restoring it would only start that over on every pass. The profile
        // keeps the mirror from coming up empty, which is the lost-store
        // path and pulls everything again.
        try server.upsert(profilePayload())
        try server.upsert(Codec.payload(for: channelState(), previous: nil))
        let transport = try makeTransport()
        try await transport.pull()
        try dropRows(UserContentState.self)

        let result = try await transport.pull()

        #expect(!result.mirrorChanged)
        #expect(try rows(UserContentState.self).isEmpty)
    }

    @Test func `a row outside any playlist comes back unconditionally`() async throws {
        try server.upsert(playlistPayload())
        try server.upsert(profilePayload())
        let transport = try makeTransport()
        try await transport.pull()
        try dropRows(UserProfile.self)

        try await transport.pull()

        #expect(try rows(UserProfile.self).map(\.id) == [profileID])
    }

    @Test func `a row removed on purpose is never restored`() async throws {
        try server.upsert(playlistPayload())
        try server.upsert(Codec.payload(for: channelState(), previous: nil))
        let transport = try makeTransport()
        try await transport.pull()
        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<UserContentState>()).first)
        log.delete(row, in: context)
        try context.save()

        try await transport.pull()

        #expect(try rows(UserContentState.self).isEmpty)
    }

    @Test func `a row pending deletion is never restored`() async throws {
        try server.upsert(playlistPayload())
        try server.upsert(Codec.payload(for: channelState(), previous: nil))
        let transport = try makeTransport()
        try await transport.pull()
        try await transport.recordDeletion(logicalKey: channelKey)

        try await transport.pull()

        #expect(try rows(UserContentState.self).isEmpty)
        #expect(try state(for: channelKey)?.isDeletionPending == true)
    }

    // MARK: Recorded removals

    @Test func `a removal becomes a tombstone on the next push`() async throws {
        try server.upsert(playlistPayload())
        try server.upsert(Codec.payload(for: channelState(), previous: nil))
        let transport = try makeTransport()
        try await transport.pull()
        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<UserContentState>()).first)
        log.delete(row, in: context)
        try context.save()

        try await transport.recordRemovals(logicalKeys: log.drain())
        try await transport.push()

        let deletes = server.pushes.joined().filter(\.deleted)
        #expect(deletes.map(\.rid) == [keys.recordID(for: channelKey)])
        #expect(server.record(forKey: channelKey)?.deleted == true)
        #expect(server.record(forKey: Codec.playlistKey(id: playlistID))?.deleted == false)
        // The tombstone settled, so the next pull has nothing to restore.
        try await transport.pull()
        #expect(try rows(UserContentState.self).isEmpty)
    }

    @Test func `a removal undone before the pass sends no tombstone`() async throws {
        try server.upsert(playlistPayload())
        try server.upsert(Codec.payload(for: channelState(), previous: nil))
        let transport = try makeTransport()
        try await transport.pull()
        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<UserContentState>()).first)
        log.delete(row, in: context)
        context.insert(channelState())
        try context.save()

        try await transport.recordRemovals(logicalKeys: log.drain())
        try await transport.push()

        #expect(server.pushes.joined().allSatisfy { !$0.deleted })
        #expect(try rows(UserContentState.self).map(\.contentId) == [channelID])
        #expect(try state(for: channelKey)?.isDeletionPending == false)
    }

    @Test func `a removal of a row that never synced sends nothing`() async throws {
        let transport = try makeTransport()
        try await transport.recordRemovals(logicalKeys: [channelKey])
        try await transport.push()

        #expect(server.pushes.isEmpty)
    }
}

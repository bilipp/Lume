//
//  LumeCloudTransportPullTests.swift
//  LumeTests
//
//  `LumeCloudTransport.pull()` against an offline change feed
//  (`StubLumeCloudClient`): a fresh pull fills the mirror and the bookkeeping,
//  the cursor advances only from `/changes`, echoes are no-ops, conflicts follow
//  the collection's merge policy, tombstones never delete a local edit, and a
//  record this build can't read is held with its envelope and applied once a
//  build can. The mirror is an in-memory Lume Cloud container
//  (`cloudKitDatabase: .none`).
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Testing

@MainActor
struct LumeCloudTransportPullTests {
    private typealias Codec = LumeCloudPayloadCodec

    private let container: ModelContainer
    private let keys = LumeCloudKeys.generate()
    private let server: StubLumeCloudClient
    private let profileID = UUID(uuidString: "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
    private let playlistID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000AB01")!
    private let created = Date(timeIntervalSince1970: 1_760_000_000)
    private let edited = Date(timeIntervalSince1970: 1_760_000_100)
    private let editedLater = Date(timeIntervalSince1970: 1_760_000_200)

    init() throws {
        container = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
        server = StubLumeCloudClient(keys: keys)
    }

    // MARK: Helpers

    private func makeTransport(
        accountId: String = "acct-harbor",
        unreadableRecordTypes: Set<String> = []
    ) throws -> LumeCloudTransport {
        try LumeCloudTransport(
            client: server, container: container, rootKey: keys.rootKey, accountId: accountId,
            unreadableRecordTypes: unreadableRecordTypes
        )
    }

    /// Stores `payload` under an envelope version this build doesn't know.
    @discardableResult
    private func storeUnsupportedEnvelope(_ payload: LumeCloudPayload) throws -> RemoteRecord {
        let (rid, ciphertext) = try keys.seal(payload)
        var envelope = try #require(Base64URL.decode(ciphertext))
        envelope[envelope.startIndex] = 0x02
        return server.store(rid: rid, ciphertext: Base64URL.encode(envelope))
    }

    private func rows<Model: PersistentModel>(_: Model.Type) throws -> [Model] {
        try ModelContext(container).fetch(FetchDescriptor<Model>())
    }

    private func state(for key: String) throws -> LumeCloudRecordState? {
        try rows(LumeCloudRecordState.self).first { $0.logicalKey == key }
    }

    private func profilePayload(name: String, isChild: Bool = false, updatedAt: Date) -> LumeCloudPayload {
        Codec.payload(
            for: UserProfile(id: profileID, name: name, isChild: isChild, createdAt: created, updatedAt: updatedAt),
            previous: nil
        )
    }

    private func contentPayload(progress: Double, favorite: Bool = false, updatedAt: Date) -> LumeCloudPayload {
        Codec.payload(
            for: UserContentState(
                contentId: "movie-4711", kind: .movie, profileID: profileID,
                watchProgress: progress, isFavorite: favorite, updatedAt: updatedAt
            ),
            previous: nil
        )
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

    /// Edits the local mirror row the way a reconcile would, then saves.
    private func editLocal<Model: PersistentModel>(_: Model.Type, _ edit: (Model) -> Void) throws {
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<Model>()).first)
        edit(row)
        try context.save()
    }

    private var profileKey: String {
        Codec.profileKey(id: profileID)
    }

    // MARK: Fresh pull

    @Test func `a fresh pull fills the mirror and the bookkeeping`() async throws {
        try server.upsert(playlistPayload())
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try server.upsert(contentPayload(progress: 42, updatedAt: created))

        let result = try await makeTransport().pull()

        #expect(result == LumeCloudPullResult(nextSeq: 3, mirrorChanged: true, skippedRecords: 0))
        #expect(server.requestedSince == [0])
        #expect(try rows(SyncedPlaylist.self).map(\.name) == ["Harbor Lights"])
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova"])
        let content = try #require(try rows(UserContentState.self).first)
        #expect(content.watchProgress == 42)
        #expect(content.profileID == profileID)

        let profileState = try #require(try state(for: profileKey))
        #expect(profileState.type == "profile")
        #expect(profileState.version == 1)
        #expect(!profileState.isDirty)
        #expect(try profileState.lastSyncedPayload == (profilePayload(name: "Nova", updatedAt: created).encoded()))
        #expect(profileState.rid == keys.recordID(for: profileKey))
        #expect(try rows(LumeCloudSyncMeta.self).map(\.nextSeq) == [3])
    }

    @Test func `the next pull starts at the stored cursor and an echo changes nothing`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()

        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        let result = try await transport.pull()

        #expect(server.requestedSince == [0, 1])
        #expect(result == LumeCloudPullResult(nextSeq: 2, mirrorChanged: false, skippedRecords: 0))
        let state = try #require(try state(for: profileKey))
        #expect(state.version == 2)
        #expect(!state.isDirty)
    }

    // MARK: Three-way merge

    @Test func `a remote edit replaces an unchanged local row`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()

        try server.upsert(profilePayload(name: "Nova Prime", updatedAt: edited))
        let result = try await transport.pull()

        #expect(result.mirrorChanged)
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova Prime"])
        #expect(try state(for: profileKey)?.isDirty == false)
    }

    @Test func `a local edit survives an unchanged remote and stays dirty`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()
        try editLocal(UserProfile.self) { $0.name = "Nova Local"; $0.updatedAt = edited }

        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()

        #expect(try rows(UserProfile.self).map(\.name) == ["Nova Local"])
        let state = try #require(try state(for: profileKey))
        #expect(state.isDirty)
        #expect(state.version == 2)
    }

    @Test func `a profile conflict keeps the newer edit and the child restriction`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()
        try editLocal(UserProfile.self) { $0.name = "Nova Local"; $0.updatedAt = editedLater }

        try server.upsert(profilePayload(name: "Nova Remote", isChild: true, updatedAt: edited))
        try await transport.pull()

        let profile = try #require(try rows(UserProfile.self).first)
        #expect(profile.name == "Nova Local")
        #expect(profile.isChild)
        #expect(profile.updatedAt == editedLater)
        let state = try #require(try state(for: profileKey))
        #expect(state.isDirty)
        #expect(try state.lastSyncedPayload == (profilePayload(name: "Nova Remote", isChild: true, updatedAt: edited).encoded()))
    }

    @Test func `a content conflict keeps the progress and the favorite`() async throws {
        let transport = try makeTransport()
        try server.upsert(contentPayload(progress: 10, updatedAt: created))
        try await transport.pull()
        try editLocal(UserContentState.self) { $0.watchProgress = 300; $0.updatedAt = editedLater }

        try server.upsert(contentPayload(progress: 20, favorite: true, updatedAt: edited))
        try await transport.pull()

        let content = try #require(try rows(UserContentState.self).first)
        #expect(content.watchProgress == 300)
        #expect(content.isFavorite)
        #expect(content.updatedAt == editedLater)
        #expect(try state(for: Codec.contentKey(profileID: profileID, contentId: "movie-4711"))?.isDirty == true)
    }

    // MARK: Tombstones

    @Test func `a tombstone deletes an unchanged row`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()

        server.delete(logicalKey: profileKey)
        let result = try await transport.pull()

        #expect(result.mirrorChanged)
        #expect(try rows(UserProfile.self).isEmpty)
        let state = try #require(try state(for: profileKey))
        #expect(state.lastSyncedPayload == nil)
        #expect(state.version == 2)
        #expect(!state.isDirty)
    }

    @Test func `a tombstone never deletes a local edit`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()
        try editLocal(UserProfile.self) { $0.name = "Nova Local" }

        server.delete(logicalKey: profileKey)
        try await transport.pull()

        #expect(try rows(UserProfile.self).map(\.name) == ["Nova Local"])
        #expect(try state(for: profileKey)?.isDirty == true)
    }

    @Test func `a stale cursor resyncs and drops records the server no longer has`() async throws {
        let transport = try makeTransport()
        try server.upsert(playlistPayload())
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()

        server.delete(logicalKey: profileKey)
        try server.upsert(contentPayload(progress: 5, updatedAt: edited))
        server.compact()
        try await transport.pull()

        #expect(server.requestedSince == [0, 2, 0])
        #expect(try rows(UserProfile.self).isEmpty)
        #expect(try rows(SyncedPlaylist.self).count == 1)
        #expect(try rows(UserContentState.self).count == 1)
    }

    // MARK: Records this build can't read

    @Test func `an unsupported envelope is skipped and kept`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()
        let before = try #require(try state(for: profileKey)?.lastSyncedPayload)

        let held = try storeUnsupportedEnvelope(profilePayload(name: "Nova Next", updatedAt: edited))
        let result = try await transport.pull()

        #expect(result == LumeCloudPullResult(nextSeq: 2, mirrorChanged: false, skippedRecords: 1))
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova"])
        let state = try #require(try state(for: profileKey))
        #expect(state.version == 1)
        #expect(state.lastSyncedPayload == before)
        #expect(state.isUndecodable)
        #expect(state.undecodableCiphertext == held.ciphertext)
        #expect(state.undecodableVersion == 2)
        #expect(state.undecodableSeq == 2)
    }

    @Test func `a held record stays held while it can't be read and a newer version releases it`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()
        try storeUnsupportedEnvelope(profilePayload(name: "Nova Next", updatedAt: edited))
        try await transport.pull()

        let again = try await transport.pull()
        #expect(again == LumeCloudPullResult(nextSeq: 2, mirrorChanged: false, skippedRecords: 1))
        #expect(try state(for: profileKey)?.isUndecodable == true)

        try server.upsert(profilePayload(name: "Nova Prime", updatedAt: editedLater))
        let released = try await transport.pull()

        #expect(released == LumeCloudPullResult(nextSeq: 3, mirrorChanged: true, skippedRecords: 0))
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova Prime"])
        let state = try #require(try state(for: profileKey))
        #expect(!state.isUndecodable)
        #expect(state.undecodableCiphertext == nil)
        #expect(state.version == 3)
    }

    @Test func `an unknown record type is held with its envelope`() async throws {
        let payload = LumeCloudPayload(type: "watchParty", key: "watchParty/lagoon", data: ["host": .string("Nova")])
        let record = try server.upsert(payload)

        let result = try await makeTransport().pull()

        #expect(!result.mirrorChanged)
        #expect(result.nextSeq == 1)
        #expect(try rows(UserProfile.self).isEmpty)
        let state = try #require(try state(for: "watchParty/lagoon"))
        #expect(state.type == "watchParty")
        #expect(state.rid == record.rid)
        #expect(state.isUndecodable)
        #expect(state.undecodableCiphertext == record.ciphertext)
        #expect(state.undecodableVersion == 1)
        #expect(state.undecodableSeq == 1)
        #expect(state.lastSyncedPayload == nil)
        #expect(!state.isDirty)
    }

    @Test func `an unknown record type applies once a later build knows it`() async throws {
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        let olderBuild = try makeTransport(unreadableRecordTypes: [UserProfile.lumeCloudType])
        let first = try await olderBuild.pull()
        #expect(!first.mirrorChanged)
        #expect(try rows(UserProfile.self).isEmpty)
        #expect(try state(for: profileKey)?.isUndecodable == true)

        let result = try await makeTransport().pull()

        #expect(server.requestedSince == [0, 1])
        #expect(result == LumeCloudPullResult(nextSeq: 1, mirrorChanged: true, skippedRecords: 0))
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova"])
        let state = try #require(try state(for: profileKey))
        #expect(!state.isUndecodable)
        #expect(state.undecodableCiphertext == nil)
        #expect(state.version == 1)
        #expect(try state.lastSyncedPayload == (profilePayload(name: "Nova", updatedAt: created).encoded()))
        #expect(!state.isDirty)
    }

    @Test func `a held record survives a bookkeeping reset and a snapshot drops one the server lost`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        let kept = try server.upsert(LumeCloudPayload(type: "watchParty", key: "watchParty/lagoon", data: [:]))
        try server.upsert(LumeCloudPayload(type: "watchParty", key: "watchParty/reef", data: [:]))
        try await transport.pull()
        server.delete(logicalKey: "watchParty/reef")
        server.compact()
        let context = ModelContext(container)
        try context.delete(model: UserProfile.self)
        try context.save()

        try await transport.pull()

        #expect(server.requestedSince == [0, 0])
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova"])
        let held = try #require(try state(for: "watchParty/lagoon"))
        #expect(held.isUndecodable)
        #expect(held.undecodableCiphertext == kept.ciphertext)
        #expect(try state(for: "watchParty/reef")?.isUndecodable != true)
    }

    // MARK: Bookkeeping safety

    @Test func `bookkeeping of another account is reset`() async throws {
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await makeTransport(accountId: "acct-harbor").pull()

        try await makeTransport(accountId: "acct-lagoon").pull()

        #expect(server.requestedSince == [0, 0])
        #expect(try rows(LumeCloudSyncMeta.self).map(\.accountId) == ["acct-lagoon"])
    }

    @Test func `an emptied mirror resets the cursor and pulls everything again`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()
        let context = ModelContext(container)
        try context.delete(model: UserProfile.self)
        try context.save()

        try await transport.pull()

        #expect(server.requestedSince == [0, 0])
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova"])
    }
}

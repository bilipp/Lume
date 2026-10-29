//
//  LumeCloudTransportPushTests.swift
//  LumeTests
//
//  `LumeCloudTransport.push()` against an offline change feed
//  (`StubLumeCloudClient`): only rows whose canonical payload changed go out,
//  requests stay within the record-count and body-size caps, duplicate rows
//  collapse to the newest, conflicts merge and retry at most three rounds, and a
//  tombstone goes out only for a recorded deletion, and a record held because
//  this build can't read it is never written over or deleted. The mirror is an
//  in-memory Lume Cloud container (`cloudKitDatabase: .none`).
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Synchronization
import Testing

@MainActor
struct LumeCloudTransportPushTests {
    private typealias Codec = LumeCloudPayloadCodec

    private let container: ModelContainer
    private let keys = LumeCloudKeys.generate()
    private let server: StubLumeCloudClient
    private let profileID = UUID(uuidString: "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
    private let otherProfileID = UUID(uuidString: "7A2B3C4D-5E6F-4B7C-9D8E-0F1A2B3C4D5E")!
    private let playlistID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000AB01")!
    private let created = Date(timeIntervalSince1970: 1_760_000_000)
    private let edited = Date(timeIntervalSince1970: 1_760_000_100)
    private let editedLater = Date(timeIntervalSince1970: 1_760_000_200)

    init() throws {
        container = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
        server = StubLumeCloudClient(keys: keys)
    }

    // MARK: Helpers

    private func makeTransport(unreadableRecordTypes: Set<String> = []) throws -> LumeCloudTransport {
        try LumeCloudTransport(
            client: server, container: container, rootKey: keys.rootKey, accountId: "acct-harbor",
            unreadableRecordTypes: unreadableRecordTypes
        )
    }

    private func rows<Model: PersistentModel>(_: Model.Type) throws -> [Model] {
        try ModelContext(container).fetch(FetchDescriptor<Model>())
    }

    private func state(for key: String) throws -> LumeCloudRecordState? {
        try rows(LumeCloudRecordState.self).first { $0.logicalKey == key }
    }

    private func insert(_ models: [any PersistentModel]) throws {
        let context = ModelContext(container)
        for model in models {
            context.insert(model)
        }
        try context.save()
    }

    private func editLocal<Model: PersistentModel>(_: Model.Type, _ edit: (Model) -> Void) throws {
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<Model>()).first)
        edit(row)
        try context.save()
    }

    private func profile(_ id: UUID? = nil, name: String, isChild: Bool = false, updatedAt: Date) -> UserProfile {
        UserProfile(id: id ?? profileID, name: name, isChild: isChild, createdAt: created, updatedAt: updatedAt)
    }

    private func profilePayload(_ id: UUID? = nil, name: String, isChild: Bool = false, updatedAt: Date) -> LumeCloudPayload {
        Codec.payload(for: profile(id, name: name, isChild: isChild, updatedAt: updatedAt), previous: nil)
    }

    private func content(_ contentId: String, progress: Double = 42) -> UserContentState {
        UserContentState(contentId: contentId, kind: .movie, profileID: profileID, watchProgress: progress, updatedAt: created)
    }

    private func playlist(id: UUID? = nil, name: String = "Harbor Lights", hiddenTabsRaw: String = "") -> SyncedPlaylist {
        SyncedPlaylist(
            id: id ?? playlistID, name: name, serverURL: "http://provider.example:8080",
            username: "viewer", password: "secret", sourceTypeRaw: PlaylistSourceType.xtream.rawValue,
            epgURL: nil, syncEnabled: true, hiddenTabsRaw: hiddenTabsRaw, updatedAt: created
        )
    }

    private var profileKey: String {
        Codec.profileKey(id: profileID)
    }

    private var playlistKey: String {
        Codec.playlistKey(id: playlistID)
    }

    private func pushedRIDs(_ request: Int) -> Set<String> {
        Set(server.pushes[request].map(\.rid))
    }

    private func bookkeeping() throws -> Bookkeeping {
        let records = try rows(LumeCloudRecordState.self).map { state in
            BookkeepingRecord(
                rid: state.rid, logicalKey: state.logicalKey, type: state.type, version: state.version,
                lastSyncedPayload: state.lastSyncedPayload, isDirty: state.isDirty,
                isDeletionPending: state.isDeletionPending, isUndecodable: state.isUndecodable,
                undecodableCiphertext: state.undecodableCiphertext, undecodableVersion: state.undecodableVersion,
                undecodableSeq: state.undecodableSeq
            )
        }
        let meta = try rows(LumeCloudSyncMeta.self).first
        return Bookkeeping(records: records.sorted { $0.rid < $1.rid }, nextSeq: meta?.nextSeq, accountId: meta?.accountId)
    }

    // MARK: Diffing

    @Test func `only records that changed since they last synced are pushed`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try server.upsert(profilePayload(otherProfileID, name: "Orbit", updatedAt: created))
        try await transport.pull()
        let context = ModelContext(container)
        let nova = try #require(context.fetch(FetchDescriptor<UserProfile>()).first { $0.id == profileID })
        nova.name = "Nova Local"
        nova.updatedAt = edited
        try context.save()
        try insert([playlist()])

        let result = try await transport.push()

        #expect(result == LumeCloudPushResult(pushedRecords: 2, rounds: 1))
        #expect(server.pushes.count == 1)
        #expect(pushedRIDs(0) == [keys.recordID(for: profileKey), keys.recordID(for: playlistKey)])
        #expect(try server.payload(forKey: profileKey)?.data["name"] == .string("Nova Local"))
        let profileState = try #require(try state(for: profileKey))
        #expect(profileState.version == 2)
        #expect(!profileState.isDirty)
        #expect(try state(for: playlistKey)?.version == 1)

        let again = try await transport.push()
        #expect(again == LumeCloudPushResult())
        #expect(server.pushes.count == 1)
    }

    @Test func `an unchanged push saves nothing and leaves the bookkeeping as it was`() async throws {
        let transport = try makeTransport()
        try insert([profile(name: "Nova", updatedAt: created), playlist()])
        let saves = TransportSaves(container: container)
        defer { saves.stop() }
        try await transport.push()
        #expect(saves.count > 0)
        #expect(await transport.upsertEncodeCount == 2)
        let before = try bookkeeping()
        let savesBefore = saves.count

        let again = try await transport.push()

        #expect(again == LumeCloudPushResult())
        #expect(server.pushes.count == 1)
        #expect(saves.count == savesBefore)
        #expect(try bookkeeping() == before)
    }

    @Test func `a pull with nothing new saves nothing`() async throws {
        let transport = try makeTransport()
        try insert([profile(name: "Nova", updatedAt: created)])
        try await transport.push()
        try await transport.pull()
        let saves = TransportSaves(container: container)
        defer { saves.stop() }
        let before = try bookkeeping()

        let pulled = try await transport.pull()

        #expect(!pulled.mirrorChanged)
        #expect(saves.count == 0)
        #expect(try bookkeeping() == before)
    }

    @Test func `a pushed record echoed back by the next pull changes nothing`() async throws {
        let transport = try makeTransport()
        try insert([playlist()])
        try await transport.push()

        let pulled = try await transport.pull()

        #expect(!pulled.mirrorChanged)
        #expect(try state(for: playlistKey)?.isDirty == false)
        #expect(try await transport.push() == LumeCloudPushResult())
    }

    @Test func `a sub-millisecond date change is not pushed`() async throws {
        let transport = try makeTransport()
        try insert([profile(name: "Nova", updatedAt: created)])
        try await transport.push()

        try editLocal(UserProfile.self) { $0.updatedAt = created.addingTimeInterval(0.0004) }

        #expect(try await transport.push() == LumeCloudPushResult())
        #expect(server.pushes.count == 1)
    }

    // MARK: Batching

    @Test func `pushes are split at the record cap and report progress`() async throws {
        let transport = try makeTransport()
        try insert((0 ..< 1001).map { content("movie-\($0)") })
        let reports = Mutex<[LumeCloudUploadProgress]>([])

        let result = try await transport.push { progress in reports.withLock { $0.append(progress) } }

        #expect(result.pushedRecords == 1001)
        #expect(server.pushes.map(\.count) == [500, 500, 1])
        #expect(reports.withLock { $0 }.map(\.completed) == [0, 500, 1000, 1001])
        #expect(reports.withLock { $0 }.allSatisfy { $0.total == 1001 })
    }

    @Test func `a push that fits one request reports no progress`() async throws {
        let transport = try makeTransport()
        try insert([content("movie-1"), content("movie-2")])
        let reports = Mutex<[LumeCloudUploadProgress]>([])

        try await transport.push { progress in reports.withLock { $0.append(progress) } }

        #expect(reports.withLock { $0 }.isEmpty)
    }

    @Test func `pushes are split at the body size cap`() async throws {
        let transport = try makeTransport()
        let bulk = String(repeating: "t", count: 60000)
        try insert((0 ..< 60).map { index in
            playlist(id: UUID(), name: "Lagoon \(index)", hiddenTabsRaw: bulk)
        })

        let result = try await transport.push()

        #expect(result.pushedRecords == 60)
        #expect(server.pushes.count == 2)
        for request in server.pushes {
            let body = try JSONEncoder().encode(["records": request])
            #expect(body.count <= LumeCloudTransport.maxPushBodyBytes)
        }
    }

    @Test func `a record over the size limit is skipped`() async throws {
        let transport = try makeTransport()
        try insert([playlist(name: String(repeating: "n", count: 70000)), content("movie-1")])

        let result = try await transport.push()

        #expect(result == LumeCloudPushResult(pushedRecords: 1, rounds: 1, skippedRecords: 1))
        #expect(server.pushes.joined().map(\.rid) == [keys.recordID(for: Codec.contentKey(profileID: profileID, contentId: "movie-1"))])
    }

    // MARK: Duplicates

    @Test func `duplicate rows collapse to the newest before pushing`() async throws {
        let transport = try makeTransport()
        try insert([profile(name: "Nova Old", updatedAt: created), profile(name: "Nova New", updatedAt: edited)])

        let result = try await transport.push()

        #expect(result.mirrorChanged)
        #expect(result.pushedRecords == 1)
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova New"])
        #expect(try server.payload(forKey: profileKey)?.data["name"] == .string("Nova New"))
    }

    // MARK: Conflicts

    @Test func `a conflict merges the server version and retries`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()
        try server.upsert(profilePayload(name: "Nova Remote", isChild: true, updatedAt: edited))
        try editLocal(UserProfile.self) { $0.name = "Nova Local"; $0.updatedAt = editedLater }

        let result = try await transport.push()

        #expect(result == LumeCloudPushResult(pushedRecords: 1, conflicts: 1, rounds: 2, mirrorChanged: true))
        let pushed = try #require(try server.payload(forKey: profileKey))
        #expect(pushed.data["name"] == .string("Nova Local"))
        #expect(pushed.data["isChild"] == .bool(true))
        #expect(try rows(UserProfile.self).first?.isChild == true)
        let state = try #require(try state(for: profileKey))
        #expect(state.version == 3)
        #expect(!state.isDirty)
    }

    @Test func `conflicts retry at most three rounds`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()
        try editLocal(UserProfile.self) { $0.name = "Nova Local"; $0.updatedAt = editedLater }
        let remote = profilePayload(name: "Nova Remote", updatedAt: edited)
        server.beforePush.withLock { $0 = { server in try server.upsert(remote) } }

        let result = try await transport.push()

        #expect(result.rounds == 3)
        #expect(result.conflicts == 3)
        #expect(result.pushedRecords == 0)
        #expect(server.pushes.count == 3)
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova Local"])
        #expect(try state(for: profileKey)?.isDirty == true)
    }

    // MARK: Tombstones

    @Test func `a tombstone goes out only for a recorded deletion`() async throws {
        let transport = try makeTransport()
        try server.upsert(Codec.payload(for: playlist(), previous: nil))
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try insert([content("movie-1")])
        try await transport.pull()
        let context = ModelContext(container)
        try context.delete(model: UserProfile.self)
        try context.save()

        try await transport.recordDeletion(logicalKey: playlistKey)
        let result = try await transport.push()

        #expect(try rows(SyncedPlaylist.self).isEmpty)
        let deletes = server.pushes.joined().filter(\.deleted)
        #expect(deletes.map(\.rid) == [keys.recordID(for: playlistKey)])
        #expect(result.pushedRecords == 2)
        #expect(server.record(forKey: playlistKey)?.deleted == true)
        #expect(server.record(forKey: profileKey)?.deleted == false)
        let state = try #require(try state(for: playlistKey))
        #expect(state.lastSyncedPayload == nil)
        #expect(!state.isDeletionPending)
        #expect(!state.isDirty)
    }

    @Test func `a deletion that never synced queues nothing`() async throws {
        let transport = try makeTransport()
        try insert([playlist(), content("movie-1")])

        try await transport.recordDeletion(logicalKey: playlistKey)
        try await transport.push()

        #expect(server.pushes.joined().allSatisfy { !$0.deleted })
        #expect(server.record(forKey: playlistKey) == nil)
    }

    @Test func `a deletion that empties the mirror pushes its tombstone`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()

        try await transport.recordDeletion(logicalKey: profileKey)
        let result = try await transport.push()

        #expect(result.pushedRecords == 1)
        #expect(server.record(forKey: profileKey)?.deleted == true)
    }

    @Test func `a deletion conflicting with a remote edit keeps the edit`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try insert([content("movie-1")])
        try await transport.pull()
        try server.upsert(profilePayload(name: "Nova Remote", updatedAt: edited))

        try await transport.recordDeletion(logicalKey: profileKey)
        let result = try await transport.push()

        #expect(result.conflicts == 1)
        #expect(result.mirrorChanged)
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova Remote"])
        #expect(server.record(forKey: profileKey)?.deleted == false)
        let state = try #require(try state(for: profileKey))
        #expect(!state.isDeletionPending)
        #expect(!state.isDirty)
    }

    // MARK: Held records

    @Test func `a push never writes over or deletes an unsupported envelope`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try insert([content("movie-1")])
        try await transport.pull()
        let (rid, ciphertext) = try keys.seal(profilePayload(name: "Nova Next", updatedAt: edited))
        var envelope = try #require(Base64URL.decode(ciphertext))
        envelope[envelope.startIndex] = 0x02
        let held = server.store(rid: rid, ciphertext: Base64URL.encode(envelope))
        try await transport.pull()
        try editLocal(UserProfile.self) { $0.name = "Nova Local"; $0.updatedAt = editedLater }

        let result = try await transport.push()

        #expect(result.skippedRecords == 1)
        #expect(!server.pushes.joined().contains { $0.rid == rid })
        #expect(server.record(forKey: profileKey) == held)

        try await transport.recordDeletion(logicalKey: profileKey)
        try await transport.push()

        #expect(!server.pushes.joined().contains { $0.rid == rid })
        #expect(server.record(forKey: profileKey) == held)
        #expect(try state(for: profileKey)?.isUndecodable == true)
    }

    @Test func `a push never writes over a record of a type this build doesn't know`() async throws {
        let remote = try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        let olderBuild = try makeTransport(unreadableRecordTypes: [UserProfile.lumeCloudType])
        try await olderBuild.pull()
        try insert([profile(name: "Nova Local", updatedAt: edited)])

        let result = try await olderBuild.push()

        #expect(result.skippedRecords == 1)
        #expect(server.pushes.isEmpty)
        #expect(server.record(forKey: profileKey) == remote)
        #expect(try state(for: profileKey)?.isUndecodable == true)
    }
}

// MARK: - History

/// Change detection through persistent history: once a push stored a token,
/// the next one encodes only the rows another context changed since.
extension LumeCloudTransportPushTests {
    private func contentRows(_ count: Int) -> [any PersistentModel] {
        (0 ..< count).map { content("movie-\($0)") }
    }

    private func editContent(_ contentId: String, progress: Double) throws {
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<UserContentState>()).first { $0.contentId == contentId })
        row.watchProgress = progress
        try context.save()
    }

    private func encodes(_ transport: LumeCloudTransport, during push: () async throws -> Void) async throws -> Int {
        let before = await transport.upsertEncodeCount
        try await push()
        return await transport.upsertEncodeCount - before
    }

    private func storedHistoryToken() throws -> Data? {
        try rows(LumeCloudSyncMeta.self).first?.historyToken
    }

    private func setStoredHistoryToken(_ token: Data?) throws {
        let context = ModelContext(container)
        try #require(context.fetch(FetchDescriptor<LumeCloudSyncMeta>()).first).historyToken = token
        try context.save()
    }

    @Test func `a row another context changes is detected and pushed`() async throws {
        let transport = try makeTransport()
        try insert(contentRows(20))
        #expect(try await encodes(transport) { try await transport.push() } == 20)
        #expect(try storedHistoryToken() != nil)

        try editContent("movie-7", progress: 90)
        var result = LumeCloudPushResult()
        let encoded = try await encodes(transport) { result = try await transport.push() }

        #expect(encoded == 1)
        #expect(result.pushedRecords == 1)
        let key = Codec.contentKey(profileID: profileID, contentId: "movie-7")
        #expect(pushedRIDs(1) == [keys.recordID(for: key)])
        #expect(try server.payload(forKey: key)?.data["watchProgress"] == .number(90))
    }

    @Test func `untouched rows are not encoded again`() async throws {
        let transport = try makeTransport()
        try insert(contentRows(50))
        try await transport.push()

        #expect(try await encodes(transport) { try await transport.push() } == 0)
        try await transport.pull()
        #expect(try await encodes(transport) { try await transport.push() } == 0)
        try editContent("movie-3", progress: 10)
        #expect(try await encodes(transport) { try await transport.push() } == 1)
        #expect(server.pushes.count == 2)
    }

    @Test func `a cleared history token falls back to a full diff`() async throws {
        let transport = try makeTransport()
        try insert(contentRows(20))
        try await transport.push()
        try setStoredHistoryToken(nil)
        try editContent("movie-2", progress: 5)

        #expect(try await encodes(transport) { try await transport.push() } == 20)
        #expect(server.pushes.count == 2)
        #expect(pushedRIDs(1).count == 1)
        #expect(try storedHistoryToken() != nil)
    }

    @Test func `a wiped mirror falls back to a full diff`() async throws {
        let transport = try makeTransport()
        try insert(contentRows(20))
        try await transport.push()
        let context = ModelContext(container)
        try context.delete(model: UserContentState.self)
        try context.save()

        try await transport.push()
        #expect(try storedHistoryToken() == nil)
        try await transport.pull()
        #expect(try rows(UserContentState.self).count == 20)

        // The pull wrote every row as the transport; only a full diff reads them.
        #expect(try await encodes(transport) { try await transport.push() } == 20)
        #expect(server.pushes.count == 1)
    }

    @Test func `an expired history token falls back to a full diff`() async throws {
        let transport = try makeTransport()
        try insert(contentRows(20))
        try await transport.push()
        let expired = try #require(try storedHistoryToken())
        try editContent("movie-1", progress: 11)
        try await transport.push()
        try editContent("movie-2", progress: 12)
        try await transport.push()
        #expect(try storedHistoryToken() != expired)
        try setStoredHistoryToken(expired)
        try editContent("movie-3", progress: 13)

        #expect(try await encodes(transport) { try await transport.push() } == 20)
        #expect(server.pushes.count == 4)
        #expect(pushedRIDs(3) == [keys.recordID(for: Codec.contentKey(profileID: profileID, contentId: "movie-3"))])
    }

    @Test func `a record whose send failed is pushed again without a full diff`() async throws {
        let transport = try makeTransport()
        try insert(contentRows(20))
        try await transport.push()
        try editContent("movie-4", progress: 44)
        server.pushError.withLock { $0 = { _ in .server(status: 500, code: "internal") } }
        await #expect(throws: (any Error).self) { try await transport.push() }
        server.pushError.withLock { $0 = nil }

        let encoded = try await encodes(transport) { try await transport.push() }

        #expect(encoded == 1)
        let key = Codec.contentKey(profileID: profileID, contentId: "movie-4")
        #expect(try server.payload(forKey: key)?.data["watchProgress"] == .number(44))
    }
}

/// Every bookkeeping field, so a pass that should write nothing can be checked
/// field by field.
private nonisolated struct Bookkeeping: Equatable {
    var records: [BookkeepingRecord]
    var nextSeq: Int?
    var accountId: String?
}

private nonisolated struct BookkeepingRecord: Equatable {
    var rid, logicalKey, type: String
    var version: Int
    var lastSyncedPayload: Data?
    var isDirty, isDeletionPending, isUndecodable: Bool
    var undecodableCiphertext: String?
    var undecodableVersion, undecodableSeq: Int
}

/// Counts the saves transport contexts make on one container.
private final nonisolated class TransportSaves: Sendable {
    private let saves = Mutex(0)
    private let observer = Mutex<(any NSObjectProtocol)?>(nil)

    var count: Int {
        saves.withLock { $0 }
    }

    init(container: ModelContainer) {
        let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [self] note in
            guard let context = note.object as? ModelContext,
                  context.container === container,
                  context.author == LumeCloudTransport.contextAuthor
            else { return }
            saves.withLock { $0 += 1 }
        }
        observer.withLock { $0 = token }
    }

    func stop() {
        observer.withLock { token in
            if let token {
                NotificationCenter.default.removeObserver(token)
            }
            token = nil
        }
    }
}

//
//  LumeCloudTransportSafetyTests.swift
//  LumeTests
//
//  `LumeCloudTransport`'s safety gate and error handling against an offline
//  change feed (`StubLumeCloudClient`): a lost mirror never pushes and pulls
//  everything again while one the user's own deletions emptied pushes its
//  tombstones, a stale cursor resyncs without losing a local edit, 507
//  holds pushes while pulls go on, 429 holds every request for `Retry-After`,
//  and a record the server rejects with 413 is left out. The mirror is an
//  in-memory Lume Cloud container (`cloudKitDatabase: .none`).
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Synchronization
import Testing

/// A clock the tests move by hand.
private final nonisolated class TestClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_760_000_000))

    var now: Date {
        date.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

@MainActor
struct LumeCloudTransportSafetyTests {
    private typealias Codec = LumeCloudPayloadCodec

    private let container: ModelContainer
    private let keys = LumeCloudKeys.generate()
    private let server: StubLumeCloudClient
    private let clock = TestClock()
    private let profileID = UUID(uuidString: "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
    private let playlistID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000AB01")!
    private let created = Date(timeIntervalSince1970: 1_760_000_000)
    private let edited = Date(timeIntervalSince1970: 1_760_000_100)

    init() throws {
        container = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
        server = StubLumeCloudClient(keys: keys)
    }

    // MARK: Helpers

    private func makeTransport() throws -> LumeCloudTransport {
        let clock = clock
        return try LumeCloudTransport(
            client: server, container: container, rootKey: keys.rootKey, accountId: "acct-harbor",
            now: { clock.now }
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

    private func profilePayload(name: String, updatedAt: Date) -> LumeCloudPayload {
        Codec.payload(
            for: UserProfile(id: profileID, name: name, createdAt: created, updatedAt: updatedAt),
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

    private func content(_ contentId: String, progress: Double = 42) -> UserContentState {
        UserContentState(contentId: contentId, kind: .movie, profileID: profileID, watchProgress: progress, updatedAt: created)
    }

    private func contentKey(_ contentId: String) -> String {
        Codec.contentKey(profileID: profileID, contentId: contentId)
    }

    private var profileKey: String {
        Codec.profileKey(id: profileID)
    }

    private var playlistKey: String {
        Codec.playlistKey(id: playlistID)
    }

    // MARK: Safety gate

    @Test func `an emptied mirror pushes nothing and the next pull starts over`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try server.upsert(playlistPayload())
        try await transport.pull()
        let context = ModelContext(container)
        try context.delete(model: UserProfile.self)
        try context.delete(model: SyncedPlaylist.self)
        try context.save()

        let pushed = try await transport.push()

        #expect(pushed == LumeCloudPushResult())
        #expect(server.pushAttempts == 0)
        #expect(try rows(LumeCloudRecordState.self).isEmpty)
        #expect(try rows(LumeCloudSyncMeta.self).map(\.nextSeq) == [0])

        try await transport.pull()

        #expect(server.requestedSince == [0, 0])
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova"])
        #expect(try rows(SyncedPlaylist.self).count == 1)
        #expect(server.record(forKey: profileKey)?.deleted == false)
        #expect(server.record(forKey: playlistKey)?.deleted == false)
    }

    @Test func `a lost store resets the bookkeeping and pulls everything again`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try server.upsert(playlistPayload())
        try await transport.pull()
        let context = ModelContext(container)
        try context.delete(model: UserProfile.self)
        try context.delete(model: SyncedPlaylist.self)
        try context.save()

        #expect(await transport.recoverLostMirror())
        #expect(try rows(LumeCloudSyncMeta.self).map(\.nextSeq) == [0])

        try await transport.pull()

        #expect(server.requestedSince == [0, 0])
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova"])
        #expect(try rows(SyncedPlaylist.self).count == 1)
    }

    @Test func `a mirror the user emptied pushes its tombstones and never pulls from 0 again`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try server.upsert(playlistPayload())
        try await transport.pull()
        try await transport.recordDeletions(logicalKeys: [profileKey, playlistKey])
        #expect(try rows(UserProfile.self).isEmpty)
        #expect(try rows(SyncedPlaylist.self).isEmpty)

        #expect(await transport.recoverLostMirror() == false)
        let pushed = try await transport.push()

        #expect(pushed.pushedRecords == 2)
        #expect(server.record(forKey: profileKey)?.deleted == true)
        #expect(server.record(forKey: playlistKey)?.deleted == true)
        #expect(try rows(LumeCloudSyncMeta.self).map(\.nextSeq) == [2])

        #expect(await transport.recoverLostMirror() == false)
        try await transport.pull()

        #expect(server.requestedSince == [0, 2])
        #expect(try rows(UserProfile.self).isEmpty)
        #expect(try rows(SyncedPlaylist.self).isEmpty)
    }

    @Test func `an emptied mirror only partly explained by deletions is a lost store`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try server.upsert(playlistPayload())
        try await transport.pull()
        try await transport.recordDeletion(logicalKey: profileKey)
        let context = ModelContext(container)
        try context.delete(model: SyncedPlaylist.self)
        try context.save()

        let pushed = try await transport.push()

        #expect(pushed == LumeCloudPushResult())
        #expect(server.pushAttempts == 0)
        #expect(try rows(LumeCloudSyncMeta.self).map(\.nextSeq) == [0])
    }

    @Test func `a lost store keeps a deletion the user recorded but never pushed`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try server.upsert(playlistPayload())
        try await transport.pull()
        try await transport.recordDeletion(logicalKey: profileKey)
        let context = ModelContext(container)
        try context.delete(model: SyncedPlaylist.self)
        try context.save()

        #expect(await transport.recoverLostMirror())
        try await transport.pull()

        // The lost playlist comes back; the profile the user deleted does not.
        #expect(try rows(SyncedPlaylist.self).count == 1)
        #expect(try rows(UserProfile.self).isEmpty)

        _ = try await transport.push()

        #expect(server.record(forKey: profileKey)?.deleted == true)
        #expect(server.record(forKey: playlistKey)?.deleted == false)
    }

    @Test func `an incremental push picks the same duplicate winner as a full diff`() async throws {
        let transport = try makeTransport()
        try insert([UserProfile(id: profileID, name: "Nova New", createdAt: created, updatedAt: edited)])
        try await transport.push()

        // Only the older duplicate is new since the history token; the untouched
        // newer row must still win, as it would in a full diff.
        try insert([UserProfile(id: profileID, name: "Nova Old", createdAt: created, updatedAt: created)])
        try await transport.push()

        #expect(try rows(UserProfile.self).map(\.name) == ["Nova New"])
        #expect(try server.payload(forKey: profileKey)?.data["name"] == .string("Nova New"))
    }

    @Test func `a mirror that never synced is not an emptied one`() async throws {
        let transport = try makeTransport()
        try insert([content("movie-1")])

        let result = try await transport.push()

        #expect(result.pushedRecords == 1)
    }

    // MARK: Full resync

    @Test func `a full resync keeps a record edited here and pushes it again`() async throws {
        let transport = try makeTransport()
        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try server.upsert(playlistPayload())
        try await transport.pull()
        let context = ModelContext(container)
        let nova = try #require(context.fetch(FetchDescriptor<UserProfile>()).first)
        nova.name = "Nova Local"
        nova.updatedAt = edited
        try context.save()
        server.delete(logicalKey: profileKey)
        server.compact()

        try await transport.pull()

        #expect(server.requestedSince == [0, 2, 0])
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova Local"])
        #expect(try rows(SyncedPlaylist.self).count == 1)
        #expect(try state(for: profileKey)?.isDirty == true)

        try await transport.push()

        #expect(try server.payload(forKey: profileKey)?.data["name"] == .string("Nova Local"))
        #expect(try state(for: profileKey)?.isDirty == false)
    }

    // MARK: 507

    @Test func `a full account stops pushing and keeps pulling`() async throws {
        let transport = try makeTransport()
        try insert([content("movie-1")])
        server.pushError.withLock { $0 = { _ in .quotaExceeded } }

        await #expect(throws: LumeCloudError.quotaExceeded) { try await transport.push() }
        server.pushError.withLock { $0 = nil }
        await #expect(throws: LumeCloudError.quotaExceeded) { try await transport.push() }
        #expect(server.pushAttempts == 1)
        #expect(await transport.isQuotaExceeded)

        try server.upsert(profilePayload(name: "Nova", updatedAt: created))
        try await transport.pull()
        #expect(try rows(UserProfile.self).map(\.name) == ["Nova"])

        clock.advance(by: LumeCloudTransport.quotaRetryInterval)
        let result = try await transport.push()

        #expect(result.pushedRecords == 1)
        #expect(server.pushAttempts == 2)
        #expect(await transport.isQuotaExceeded == false)
    }

    @Test func `a deletion lifts the quota hold`() async throws {
        let transport = try makeTransport()
        try insert([content("movie-1"), content("movie-2")])
        try await transport.push()
        try insert([content("movie-3")])
        server.pushError.withLock { $0 = { _ in .quotaExceeded } }
        await #expect(throws: LumeCloudError.quotaExceeded) { try await transport.push() }
        server.pushError.withLock { $0 = nil }

        try await transport.recordDeletion(logicalKey: contentKey("movie-1"))
        let result = try await transport.push()

        #expect(result.pushedRecords == 2)
        #expect(server.record(forKey: contentKey("movie-1"))?.deleted == true)
        #expect(server.record(forKey: contentKey("movie-3"))?.deleted == false)
    }

    // MARK: 429

    @Test func `a rate limit holds every request for Retry-After`() async throws {
        let transport = try makeTransport()
        try insert([content("movie-1")])
        server.changesError.withLock { $0 = { _ in .rateLimited(retryAfter: 30) } }

        await #expect(throws: LumeCloudError.rateLimited(retryAfter: 30)) { try await transport.pull() }
        server.changesError.withLock { $0 = nil }
        clock.advance(by: 10)
        await #expect(throws: LumeCloudError.rateLimited(retryAfter: 20)) { try await transport.pull() }
        await #expect(throws: LumeCloudError.rateLimited(retryAfter: 20)) { try await transport.push() }
        #expect(server.requestedSince == [0])
        #expect(server.pushAttempts == 0)

        clock.advance(by: 20)
        try await transport.pull()
        let result = try await transport.push()

        #expect(server.requestedSince == [0, 0])
        #expect(result.pushedRecords == 1)
    }

    @Test func `a rate limit without Retry-After backs off exponentially`() async throws {
        let transport = try makeTransport()
        server.changesError.withLock { $0 = { _ in .rateLimited(retryAfter: nil) } }

        await #expect(throws: LumeCloudError.rateLimited(retryAfter: nil)) { try await transport.pull() }
        #expect(await transport.rateLimitedUntil == clock.now.addingTimeInterval(30))
        clock.advance(by: 30)
        await #expect(throws: LumeCloudError.rateLimited(retryAfter: nil)) { try await transport.pull() }
        #expect(await transport.rateLimitedUntil == clock.now.addingTimeInterval(60))

        server.changesError.withLock { $0 = nil }
        clock.advance(by: 60)
        try await transport.pull()
        #expect(await transport.consecutiveRateLimits == 0)
    }

    // MARK: 413

    @Test func `a record the server rejects as too large is left out until it changes`() async throws {
        let transport = try makeTransport()
        try insert([content("movie-1"), content("movie-2"), content("movie-3")])
        let oversized = keys.recordID(for: contentKey("movie-2"))
        server.pushError.withLock { $0 = { records in records.contains { $0.rid == oversized } ? .recordTooLarge : nil } }

        let result = try await transport.push()

        #expect(result.pushedRecords == 2)
        #expect(result.skippedRecords == 1)
        #expect(server.record(forKey: contentKey("movie-1")) != nil)
        #expect(server.record(forKey: contentKey("movie-3")) != nil)
        #expect(server.record(forKey: contentKey("movie-2")) == nil)

        server.pushError.withLock { $0 = nil }
        let attempts = server.pushAttempts
        let again = try await transport.push()
        #expect(again == LumeCloudPushResult(skippedRecords: 1))
        #expect(server.pushAttempts == attempts)

        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<UserContentState>()).first { $0.contentId == "movie-2" })
        row.watchProgress = 7
        try context.save()
        let changed = try await transport.push()

        #expect(changed.pushedRecords == 1)
        #expect(server.record(forKey: contentKey("movie-2")) != nil)
    }
}

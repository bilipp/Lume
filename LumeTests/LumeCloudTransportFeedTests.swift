//
//  LumeCloudTransportFeedTests.swift
//  LumeTests
//
//  `LumeCloudTransport` when its stored cursor belongs to another change feed.
//  The account id comes from the root key, so it survives an account moving
//  between servers (staging to production, a self-hosted server) and a server
//  restored from a backup; `seq`s and versions don't. A cursor ahead of the
//  feed skips every record up to it, so other devices' writes never arrive.
//  Covered: a recorded server change resets the bookkeeping, bookkeeping from
//  before the server was recorded keeps its cursor, a push that proves the
//  feed behind the cursor resets it, and an ordinary push never does. The
//  mirror is an in-memory Lume Cloud container (`cloudKitDatabase: .none`).
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Synchronization
import Testing

@MainActor
struct LumeCloudTransportFeedTests {
    private typealias Codec = LumeCloudPayloadCodec

    private let container: ModelContainer
    private let keys = LumeCloudKeys.generate()
    private let profileID = UUID(uuidString: "5A6B7C8D-9E0F-4A1B-8C2D-3E4F5A6B7C8D")!
    private let created = Date(timeIntervalSince1970: 1_760_000_000)
    private let stagingURL = URL(string: "https://sync-staging.example.org")!
    private let productionURL = URL(string: "https://sync.example.org")!

    init() throws {
        container = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
    }

    // MARK: Helpers

    private func makeTransport(_ client: StubLumeCloudClient, serverURL: URL) throws -> LumeCloudTransport {
        try LumeCloudTransport(
            client: client, container: container, rootKey: keys.rootKey, accountId: "acct-lighthouse",
            serverURL: serverURL
        )
    }

    private func rows<Model: PersistentModel>(_: Model.Type) throws -> [Model] {
        try ModelContext(container).fetch(FetchDescriptor<Model>())
    }

    private func meta() throws -> LumeCloudSyncMeta {
        try #require(rows(LumeCloudSyncMeta.self).first)
    }

    private func state(for key: String) throws -> LumeCloudRecordState? {
        try rows(LumeCloudRecordState.self).first { $0.logicalKey == key }
    }

    private func contentIDs() throws -> Set<String> {
        try Set(rows(UserContentState.self).map(\.contentId))
    }

    private func profilePayload(name: String) -> LumeCloudPayload {
        Codec.payload(
            for: UserProfile(id: profileID, name: name, createdAt: created, updatedAt: created),
            previous: nil
        )
    }

    private func episode(_ contentId: String) -> UserContentState {
        UserContentState(
            contentId: contentId, kind: .episode, profileID: profileID,
            watchProgress: 2400, isWatched: true, lastWatchedDate: created, updatedAt: created
        )
    }

    private func episodePayload(_ contentId: String) -> LumeCloudPayload {
        Codec.payload(for: episode(contentId), previous: nil)
    }

    private func contentKey(_ contentId: String) -> String {
        Codec.contentKey(profileID: profileID, contentId: contentId)
    }

    private var profileKey: String {
        Codec.profileKey(id: profileID)
    }

    /// Writes the profile `count` times, so the feed's head is `count`.
    private func advance(_ client: StubLumeCloudClient, by count: Int) throws {
        for index in 1 ... count {
            try client.upsert(profilePayload(name: "Lighthouse \(index)"))
        }
    }

    private func insert(_ model: some PersistentModel) throws {
        let context = ModelContext(container)
        context.insert(model)
        try context.save()
    }

    // MARK: Server change

    @Test func `bookkeeping from another server pulls everything from the new one`() async throws {
        let staging = StubLumeCloudClient(keys: keys)
        try advance(staging, by: 6)
        try await makeTransport(staging, serverURL: stagingURL).pull()
        #expect(try meta().nextSeq == 6)

        // The account moved: production holds the copied record at its own
        // seq, then another device's write — both below the staging cursor.
        let production = StubLumeCloudClient(keys: keys)
        try production.upsert(profilePayload(name: "Lighthouse 6"))
        try production.upsert(episodePayload("tide-episode-8"))
        let transport = try makeTransport(production, serverURL: productionURL)
        #expect(try await transport.storedCursor() == 0)
        try await transport.pull()

        #expect(production.requestedSince == [0])
        #expect(try contentIDs() == ["tide-episode-8"])
        #expect(try state(for: profileKey)?.version == 1)
        #expect(try meta().serverURL == LumeCloudConfig.comparable(productionURL))
        #expect(try meta().nextSeq == 2)
    }

    @Test func `a server change keeps the mirror and pushes only what the new server lacks`() async throws {
        let staging = StubLumeCloudClient(keys: keys)
        try advance(staging, by: 4)
        try staging.upsert(episodePayload("tide-episode-1"))
        try await makeTransport(staging, serverURL: stagingURL).pull()

        // Production got the profile but not the episode.
        let production = StubLumeCloudClient(keys: keys)
        try production.upsert(profilePayload(name: "Lighthouse 4"))
        let transport = try makeTransport(production, serverURL: productionURL)
        try await transport.pull()
        let result = try await transport.push()

        #expect(try contentIDs() == ["tide-episode-1"])
        #expect(result.pushedRecords == 1)
        #expect(production.record(forKey: contentKey("tide-episode-1")) != nil)
        #expect(!result.feedRewound)
        #expect(try await transport.push().pushedRecords == 0)
    }

    @Test func `bookkeeping from before the server was recorded keeps its cursor`() async throws {
        let production = StubLumeCloudClient(keys: keys)
        try advance(production, by: 3)
        try await makeTransport(production, serverURL: productionURL).pull()
        let context = ModelContext(container)
        try #require(context.fetch(FetchDescriptor<LumeCloudSyncMeta>()).first).serverURL = ""
        try context.save()

        try production.upsert(episodePayload("tide-episode-2"))
        try await makeTransport(production, serverURL: productionURL).pull()

        #expect(production.requestedSince == [0, 3])
        #expect(try contentIDs() == ["tide-episode-2"])
        #expect(try meta().serverURL == LumeCloudConfig.comparable(productionURL))
    }

    // MARK: Feed behind the cursor

    @Test func `a push that finds the feed behind the cursor starts over from 0`() async throws {
        let server = StubLumeCloudClient(keys: keys)
        try advance(server, by: 6)
        let transport = try makeTransport(server, serverURL: productionURL)
        try await transport.pull()
        // The launch check has run and passed: from here on, only a push notices.
        try await transport.pull()
        #expect(server.accountRequests == 1)

        // The feed rewinds under the same server (a restored backup, or a move
        // recorded before the server was): its head falls behind the cursor,
        // and another device's write lands below it.
        server.state.withLock { $0 = StubLumeCloudClient.State() }
        try server.upsert(profilePayload(name: "Lighthouse 6"))
        try server.upsert(episodePayload("tide-episode-9"))
        #expect(try await transport.pull().mirrorChanged == false)
        #expect(try contentIDs().isEmpty)

        try insert(episode("tide-episode-3"))
        let result = try await transport.push()
        #expect(result.feedRewound)
        #expect(result.pushedRecords == 1)
        #expect(try meta().nextSeq == 0)

        try await transport.pull()
        #expect(server.requestedSince.last == 0)
        #expect(try contentIDs() == ["tide-episode-3", "tide-episode-9"])
        #expect(try state(for: profileKey)?.version == 1)
        // The snapshot matched every row: nothing is pushed again.
        let settled = try await transport.push()
        #expect(settled.pushedRecords == 0)
        #expect(!settled.feedRewound)
    }

    @Test func `a launch whose cursor is ahead of the feed pulls everything before anything is pushed`() async throws {
        let server = StubLumeCloudClient(keys: keys)
        try advance(server, by: 6)
        try await makeTransport(server, serverURL: productionURL).pull()

        // A device that only reads: the feed rewinds, another device writes,
        // and this one has nothing to push that would reveal it.
        server.state.withLock { $0 = StubLumeCloudClient.State() }
        try server.upsert(profilePayload(name: "Lighthouse 6"))
        try server.upsert(episodePayload("tide-episode-10"))
        let relaunched = try makeTransport(server, serverURL: productionURL)
        try await relaunched.pull()

        // The rewound stub kept no history: this is the relaunch's only request.
        #expect(server.requestedSince == [0])
        #expect(server.accountRequests == 1)
        #expect(try contentIDs() == ["tide-episode-10"])
        #expect(try state(for: profileKey)?.version == 1)
        #expect(try await relaunched.push().pushedRecords == 0)
    }

    @Test func `the launch check asks once, and never on a fresh device`() async throws {
        let server = StubLumeCloudClient(keys: keys)
        try advance(server, by: 3)
        let transport = try makeTransport(server, serverURL: productionURL)
        try await transport.pull()
        #expect(server.accountRequests == 0)

        try server.upsert(episodePayload("tide-episode-6"))
        try await transport.pull()
        try await transport.pull()

        #expect(server.accountRequests == 1)
        #expect(server.requestedSince == [0, 3, 4])
        #expect(try contentIDs() == ["tide-episode-6"])
    }

    @Test func `a push on the cursor's own feed never reads as rewound`() async throws {
        let server = StubLumeCloudClient(keys: keys)
        try advance(server, by: 3)
        let transport = try makeTransport(server, serverURL: productionURL)
        try await transport.pull()
        // Another device writes after the pull; the cursor is behind, not ahead.
        try server.upsert(episodePayload("tide-episode-4"))

        try insert(episode("tide-episode-5"))
        let result = try await transport.push()

        #expect(!result.feedRewound)
        #expect(result.pushedRecords == 1)
        #expect(try meta().nextSeq == 3)
        try await transport.pull()
        #expect(server.requestedSince == [0, 3])
        #expect(try contentIDs() == ["tide-episode-4", "tide-episode-5"])
    }

    @Test func `a conflicting push still checks the feed`() async throws {
        let server = StubLumeCloudClient(keys: keys)
        try advance(server, by: 6)
        let transport = try makeTransport(server, serverURL: productionURL)
        try await transport.pull()
        try await transport.pull()

        server.state.withLock { $0 = StubLumeCloudClient.State() }
        try server.upsert(profilePayload(name: "Lighthouse 6"))
        // The local edit's base version (6) is another feed's: it conflicts.
        let context = ModelContext(container)
        try #require(context.fetch(FetchDescriptor<UserProfile>()).first).name = "Lantern"
        try context.save()
        let result = try await transport.push()

        #expect(result.conflicts > 0)
        #expect(result.feedRewound)
        #expect(try meta().nextSeq == 0)
    }
}

//
//  CloudSyncMirrorLossTests.swift
//  LumeTests
//
//  Covers the mirror-side integrity gate. A mirror that comes back empty or
//  half-imported (CloudKit re-importing after a 134301 history reset, a wiped
//  Lume Cloud mirror) used to read as "every playlist deleted on another
//  device": the reconcile deleted the local playlists, garbage-collected their
//  Live TV favorites, hidden channels and category order, and those clears
//  reached every other device as deletions. A Mac lost its favorites for good
//  that way while the other devices still had them.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CloudSyncMirrorLossTests {
    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "cloudsync.mirrorloss.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    /// Seeds `count` playlists, each with a favorite live channel, a hidden
    /// channel and a reordered live category, then reconciles once so the
    /// mirrors and the shadow baselines exist.
    private func seedSyncedDevice(
        playlists count: Int,
        in ctx: ModelContext,
        engine: CloudSyncEngine
    ) async throws -> [UUID] {
        // Every synced install has its default profile in the mirror.
        ctx.insert(UserProfile(id: UserProfile.defaultProfileID, name: "Default"))
        var ids: [UUID] = []
        for index in 0 ..< count {
            let playlist = Playlist(name: "Provider \(index)", serverURL: "http://p\(index)", username: "u", password: "p")
            ctx.insert(playlist)
            let pid = playlist.id
            ids.append(pid)

            let favorite = LiveStream(id: "\(pid.uuidString)-live-1", streamId: 1, name: "Channel A")
            favorite.isFavorite = true
            favorite.favoriteOrder = index
            ctx.insert(favorite)

            let hidden = LiveStream(id: "\(pid.uuidString)-live-2", streamId: 2, name: "Channel B")
            hidden.isHidden = true
            ctx.insert(hidden)

            let category = Lume.Category(apiId: "7", name: "News", parentId: 0, type: .live, playlist: playlist)
            category.customOrder = 3
            ctx.insert(category)
        }
        try ctx.save()
        _ = await engine.reconcile()
        #expect(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).count == count)
        #expect(try ctx.fetch(FetchDescriptor<UserContentState>()).count == count * 3)
        return ids
    }

    private func expectUserStateIntact(playlists ids: [UUID], in ctx: ModelContext) throws {
        let localIDs = try Set(ctx.fetch(FetchDescriptor<Playlist>()).map(\.id))
        #expect(localIDs == Set(ids))
        let streams = try ctx.fetch(FetchDescriptor<LiveStream>())
        #expect(streams.count { $0.isFavorite } == ids.count)
        #expect(streams.count { $0.isHidden } == ids.count)
        let categories = try ctx.fetch(FetchDescriptor<Lume.Category>())
        #expect(categories.count == ids.count)
        #expect(categories.allSatisfy { $0.customOrder == 3 })
    }

    // MARK: - Engine

    @Test func `an emptied mirror keeps the local favorites and re-pushes them`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let ids = try await seedSyncedDevice(playlists: 3, in: ctx, engine: engine)

        // The mirror store comes back empty: CloudKit dropped its history and
        // hasn't re-imported a single record yet.
        try ctx.delete(model: SyncedPlaylist.self)
        try ctx.delete(model: UserContentState.self)
        try ctx.delete(model: UserProfile.self)
        try ctx.save()

        let result = await engine.reconcile()

        #expect(result.recoveredFromLostMirror)
        try expectUserStateIntact(playlists: ids, in: ctx)
        // Merged back into the mirror instead of cleared out of it.
        #expect(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).count == 3)
        let states = try ctx.fetch(FetchDescriptor<UserContentState>())
        #expect(states.count == 9)
        #expect(states.count { $0.isFavorite } == 3)
        #expect(states.count { $0.kind == .category && $0.customOrder == 3 } == 3)

        // The pass after recovery is an ordinary one.
        let next = await engine.reconcile()
        #expect(!next.recoveredFromLostMirror)
        try expectUserStateIntact(playlists: ids, in: ctx)
    }

    @Test func `a half-imported mirror deletes nothing`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let ids = try await seedSyncedDevice(playlists: 4, in: ctx, engine: engine)

        // Mid-import: the profiles and one playlist are back, the rest and
        // every content state aren't yet.
        let keep = ids[0]
        try ctx.delete(model: SyncedPlaylist.self, where: #Predicate { $0.id != keep })
        try ctx.delete(model: UserContentState.self)
        try ctx.save()

        let result = await engine.reconcile()

        #expect(result.recoveredFromLostMirror)
        try expectUserStateIntact(playlists: ids, in: ctx)
        #expect(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).count == 4)
    }

    @Test func `playlists back but content states not yet keeps the favorites`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let ids = try await seedSyncedDevice(playlists: 2, in: ctx, engine: engine)

        try ctx.delete(model: UserContentState.self)
        try ctx.save()

        let result = await engine.reconcile()

        #expect(result.recoveredFromLostMirror)
        try expectUserStateIntact(playlists: ids, in: ctx)
        #expect(try ctx.fetch(FetchDescriptor<UserContentState>()).count == 6)
    }

    @Test func `a playlist deleted on another device still propagates`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let ids = try await seedSyncedDevice(playlists: 3, in: ctx, engine: engine)

        // What another device's `deletePlaylist` leaves in the mirror: that
        // playlist's row and its content states gone, everything else intact.
        let gone = ids[1]
        let prefix = gone.uuidString
        try ctx.delete(model: SyncedPlaylist.self, where: #Predicate { $0.id == gone })
        try ctx.delete(model: UserContentState.self, where: #Predicate { $0.contentId.starts(with: prefix) })
        try ctx.save()

        let result = await engine.reconcile()

        #expect(!result.recoveredFromLostMirror)
        #expect(try Set(ctx.fetch(FetchDescriptor<Playlist>()).map(\.id)) == Set([ids[0], ids[2]]))
        #expect(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).count == 2)
    }

    @Test func `a single-playlist user deleting it on another device still propagates`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = try await seedSyncedDevice(playlists: 1, in: ctx, engine: engine)

        try ctx.delete(model: SyncedPlaylist.self)
        try ctx.delete(model: UserContentState.self)
        try ctx.save()

        let result = await engine.reconcile()

        #expect(!result.recoveredFromLostMirror)
        #expect(try ctx.fetch(FetchDescriptor<Playlist>()).isEmpty)
    }

    @Test func `an un-favorite on another device still propagates`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let ids = try await seedSyncedDevice(playlists: 2, in: ctx, engine: engine)

        let favoriteID = "\(ids[0].uuidString)-live-1"
        try ctx.delete(model: UserContentState.self, where: #Predicate { $0.contentId == favoriteID })
        try ctx.save()

        let result = await engine.reconcile()

        #expect(!result.recoveredFromLostMirror)
        let stream = try #require(try ctx.fetch(FetchDescriptor<LiveStream>()).first { $0.id == favoriteID })
        #expect(!stream.isFavorite)
    }

    // MARK: - Classifier

    @Test func `a mirror holding every baselined record is ready`() {
        let probe = CloudSyncEngine.MirrorProbe(
            baselinedPlaylists: 5, missingPlaylists: 0, mirrorHasProfiles: true, baselinedContent: 40, mirrorContent: 40
        )
        #expect(CloudSyncEngine.mirrorReadiness(probe) == .ready)
    }

    @Test func `a fresh device with no baseline is ready`() {
        let probe = CloudSyncEngine.MirrorProbe(
            baselinedPlaylists: 0, missingPlaylists: 0, mirrorHasProfiles: false, baselinedContent: 0, mirrorContent: 0
        )
        #expect(CloudSyncEngine.mirrorReadiness(probe) == .ready)
    }

    @Test func `every baselined playlist gone at once is a lost mirror`() {
        let probe = CloudSyncEngine.MirrorProbe(
            baselinedPlaylists: 2, missingPlaylists: 2, mirrorHasProfiles: true, baselinedContent: 0, mirrorContent: 0
        )
        #expect(CloudSyncEngine.mirrorReadiness(probe) == .lostButHadData)
    }

    @Test func `the only playlist gone with its profiles is a lost mirror`() {
        let probe = CloudSyncEngine.MirrorProbe(
            baselinedPlaylists: 1, missingPlaylists: 1, mirrorHasProfiles: false, baselinedContent: 0, mirrorContent: 0
        )
        #expect(CloudSyncEngine.mirrorReadiness(probe) == .lostButHadData)
    }

    @Test func `the only playlist gone while profiles remain is a deletion`() {
        let probe = CloudSyncEngine.MirrorProbe(
            baselinedPlaylists: 1, missingPlaylists: 1, mirrorHasProfiles: true, baselinedContent: 0, mirrorContent: 0
        )
        #expect(CloudSyncEngine.mirrorReadiness(probe) == .ready)
    }

    @Test func `most of many playlists gone at once is a lost mirror`() {
        let probe = CloudSyncEngine.MirrorProbe(
            baselinedPlaylists: 10, missingPlaylists: 6, mirrorHasProfiles: true, baselinedContent: 0, mirrorContent: 0
        )
        #expect(CloudSyncEngine.mirrorReadiness(probe) == .lostButHadData)
    }

    @Test func `one or two of many playlists gone is a deletion`() {
        for missing in 1 ... 2 {
            let probe = CloudSyncEngine.MirrorProbe(
                baselinedPlaylists: 10, missingPlaylists: missing, mirrorHasProfiles: true, baselinedContent: 0, mirrorContent: 0
            )
            #expect(CloudSyncEngine.mirrorReadiness(probe) == .ready)
        }
    }

    @Test func `every content state gone is a lost mirror`() {
        let probe = CloudSyncEngine.MirrorProbe(
            baselinedPlaylists: 2, missingPlaylists: 0, mirrorHasProfiles: true, baselinedContent: 3, mirrorContent: 0
        )
        #expect(CloudSyncEngine.mirrorReadiness(probe) == .lostButHadData)
    }

    @Test func `a couple of cleared states is an edit`() {
        let probe = CloudSyncEngine.MirrorProbe(
            baselinedPlaylists: 2, missingPlaylists: 0, mirrorHasProfiles: true, baselinedContent: 2, mirrorContent: 0
        )
        #expect(CloudSyncEngine.mirrorReadiness(probe) == .ready)
    }
}

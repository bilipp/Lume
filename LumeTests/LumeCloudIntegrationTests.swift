//
//  LumeCloudIntegrationTests.swift
//  LumeTests
//
//  End to end through `CloudSyncCoordinator`: real engine passes over an
//  in-memory catalog, the iCloud mirror and the Lume Cloud store (all
//  `cloudKitDatabase: .none`), with `StubLumeCloudAccountServer` and its
//  `StubLumeCloudClient` feed in place of the server. A round trip iCloud →
//  Lume Cloud → iCloud keeps every favourite, the progress and the parental
//  PIN, and a lost Lume Cloud store never turns into deletions.
//
//  The passes read the keychain PIN, so the tests live in an extension of the
//  `.serialized` `CloudSyncParentalEngineTests` suite (see
//  CloudSyncShadowNamespaceTests).
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Synchronization
import Testing

@MainActor
private struct IntegrationHarness {
    static let pin = "2468"
    static let progress = 1834.0
    static let watchedAt = Date(timeIntervalSince1970: 1_790_000_000)

    let catalog: ModelContainer
    let iCloudMirror: ModelContainer
    let defaults = LumeCloudBackendFixture.makeDefaults()
    let fixture = LumeCloudBackendFixture(keychainService: "lume.cloud.tests.integration")
    let iCloud: ICloudBackend
    let playlistID: UUID
    let favoriteMovieID: String
    let watchedMovieID: String
    let favoriteChannelID: String
    let watchedEpisodeID: String

    init() throws {
        catalog = try makeTestContainer()
        iCloudMirror = try makeICloudMirrorTestContainer()
        iCloud = ICloudBackend(mirrorContainer: iCloudMirror, cloudKitContainerIdentifier: "iCloud.test.integration", cloudKitEnabled: false)

        let context = catalog.mainContext
        let playlist = Playlist(name: "Fictional TV", serverURL: "http://x", username: "u", password: "p")
        context.insert(playlist)
        let prefix = playlist.id.uuidString
        playlistID = playlist.id
        favoriteMovieID = "\(prefix)-movie-1"
        watchedMovieID = "\(prefix)-movie-2"
        favoriteChannelID = "\(prefix)-live-1"
        watchedEpisodeID = "\(prefix)-episode-1"

        let favorite = Movie(id: favoriteMovieID, streamId: 1, name: "Harbor Lights")
        favorite.isFavorite = true
        context.insert(favorite)
        let watched = Movie(id: watchedMovieID, streamId: 2, name: "Quiet Meadow")
        watched.watchProgress = Self.progress
        watched.lastWatchedDate = Self.watchedAt
        context.insert(watched)
        let channel = LiveStream(id: favoriteChannelID, streamId: 3, name: "Lantern One")
        channel.isFavorite = true
        channel.favoriteOrder = 0
        context.insert(channel)
        let episode = Episode(id: watchedEpisodeID, episodeId: "1", title: "Pilot", containerExtension: "mkv", seasonNum: 1, episodeNum: 1)
        episode.watchProgress = Self.progress
        episode.lastWatchedDate = Self.watchedAt
        context.insert(episode)
        try context.save()
        _ = ParentalControlsStore.save(pin: Self.pin)
    }

    func makeCoordinator(backend: any SyncBackend, lumeCloud: LumeCloudBackend) -> CloudSyncCoordinator {
        CloudSyncCoordinator(
            catalogContainer: catalog,
            cloudContainer: iCloudMirror,
            backend: backend,
            iCloudBackend: iCloud,
            makeLumeCloudBackend: { lumeCloud },
            defaults: defaults,
            deletionLog: SyncMirrorDeletionLog()
        )
    }

    /// Every favourite, the progress and the PIN of this device, read back from
    /// the stores rather than from the objects inserted above.
    func expectLocalStateIntact(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let context = ModelContext(catalog)
        #expect(try context.fetch(FetchDescriptor<Playlist>()).map(\.id) == [playlistID], sourceLocation: sourceLocation)
        let movies = try Dictionary(uniqueKeysWithValues: context.fetch(FetchDescriptor<Movie>()).map { ($0.id, $0) })
        #expect(movies[favoriteMovieID]?.isFavorite == true, sourceLocation: sourceLocation)
        #expect(movies[watchedMovieID]?.watchProgress == Self.progress, sourceLocation: sourceLocation)
        #expect(movies[watchedMovieID]?.lastWatchedDate == Self.watchedAt, sourceLocation: sourceLocation)
        let channels = try context.fetch(FetchDescriptor<LiveStream>())
        #expect(channels.first { $0.id == favoriteChannelID }?.isFavorite == true, sourceLocation: sourceLocation)
        let episodes = try context.fetch(FetchDescriptor<Episode>())
        #expect(episodes.first { $0.id == watchedEpisodeID }?.watchProgress == Self.progress, sourceLocation: sourceLocation)
        #expect(ParentalControlsStore.verify(pin: Self.pin), sourceLocation: sourceLocation)
    }

    /// The content states a mirror holds, by content id.
    func contentStates(in container: ModelContainer) throws -> [String: UserContentState] {
        try Dictionary(
            ModelContext(container).fetch(FetchDescriptor<UserContentState>()).map { ($0.contentId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func expectMirrorCarriesState(_ container: ModelContainer, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let states = try contentStates(in: container)
        #expect(states[favoriteMovieID]?.isFavorite == true, sourceLocation: sourceLocation)
        #expect(states[watchedMovieID]?.watchProgress == Self.progress, sourceLocation: sourceLocation)
        #expect(states[favoriteChannelID]?.isFavorite == true, sourceLocation: sourceLocation)
        #expect(states[watchedEpisodeID]?.watchProgress == Self.progress, sourceLocation: sourceLocation)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<SyncedParentalPIN>()) == 1, sourceLocation: sourceLocation)
    }

    /// The server's record under `logicalKey`, decrypted with the account's keys;
    /// nil when there is none or it is a tombstone.
    func remotePayload(_ logicalKey: String, of backend: LumeCloudBackend) throws -> LumeCloudPayload? {
        let keys = try LumeCloudKeys(rootKey: #require(backend.identity).rootKey)
        let rid = keys.recordID(for: logicalKey)
        guard let record = fixture.server.feed.state.withLock({ $0.records[rid] }), let ciphertext = record.ciphertext else { return nil }
        return try keys.openPayload(ciphertext, rid: rid)
    }

    var pushedTombstones: Int {
        fixture.server.feed.pushes.joined().count { $0.deleted }
    }

    var liveRemoteRecords: Int {
        fixture.server.feed.state.withLock { $0.records.values.count { !$0.deleted } }
    }

    /// What a lost Lume Cloud store leaves behind: no mirror rows, while the
    /// transport's bookkeeping still lists everything as synced.
    func loseMirrorRows(of container: ModelContainer) throws {
        let context = ModelContext(container)
        try context.delete(model: SyncedPlaylist.self)
        try context.delete(model: UserContentState.self)
        try context.delete(model: UserProfile.self)
        try context.delete(model: SyncedEPGSource.self)
        try context.delete(model: SyncedParentalPIN.self)
        try context.delete(model: SyncedCategoryRestriction.self)
        try context.delete(model: SyncedSportsFollow.self)
        try context.delete(model: SyncedRecordingServer.self)
        try context.delete(model: SyncedLiveTVPreferences.self)
        try context.save()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LumeCloudRecordState>()) > 0)
    }
}

@MainActor
private func runIntegrationPass(_ coordinator: CloudSyncCoordinator) async throws {
    coordinator.status.lastReconcile = nil
    coordinator.reconcile(reason: .queued, debounced: false)
    try await waitForPass(coordinator)
}

@MainActor
private func waitForPass(_ coordinator: CloudSyncCoordinator) async throws {
    for _ in 0 ..< 400 where coordinator.status.lastReconcile == nil {
        try await Task.sleep(for: .milliseconds(25))
    }
    try #require(coordinator.status.lastReconcile != nil)
}

extension CloudSyncParentalEngineTests {
    @Test func `iCloud to Lume Cloud and back keeps every favorite, the progress and the parental PIN`() async throws {
        let harness = try IntegrationHarness()
        defer { _ = ParentalControlsStore.clear() }
        let (lumeCloud, _) = try await harness.fixture.makeJoinedBackend(defaults: harness.defaults)
        let coordinator = harness.makeCoordinator(backend: harness.iCloud, lumeCloud: lumeCloud)
        try await runIntegrationPass(coordinator)
        try harness.expectMirrorCarriesState(harness.iCloudMirror)

        coordinator.status.lastReconcile = nil
        try await coordinator.switchBackend(to: .lumecloud)
        try await waitForPass(coordinator)

        #expect(coordinator.engineNamespace == .lumecloud)
        try harness.expectLocalStateIntact()
        try harness.expectMirrorCarriesState(lumeCloud.container)
        let favorite = try #require(harness.contentStates(in: lumeCloud.container)[harness.favoriteMovieID])
        #expect(try harness.remotePayload(favorite.lumeCloudKey, of: lumeCloud)?.data["isFavorite"] == .bool(true))
        let watched = try #require(harness.contentStates(in: lumeCloud.container)[harness.watchedMovieID])
        #expect(try harness.remotePayload(watched.lumeCloudKey, of: lumeCloud)?.data["watchProgress"] == .number(IntegrationHarness.progress))
        #expect(try harness.remotePayload(LumeCloudPayloadCodec.parentalPINKey, of: lumeCloud) != nil)
        #expect(try harness.remotePayload(LumeCloudPayloadCodec.playlistKey(id: harness.playlistID), of: lumeCloud) != nil)

        // Favourited while on Lume Cloud: the way back must carry it too.
        let laterID = "\(harness.playlistID.uuidString)-movie-3"
        let later = Movie(id: laterID, streamId: 4, name: "Paper Kites")
        later.isFavorite = true
        harness.catalog.mainContext.insert(later)
        try harness.catalog.mainContext.save()
        try await runIntegrationPass(coordinator)
        let liveBeforeReturn = harness.liveRemoteRecords

        coordinator.status.lastReconcile = nil
        try await coordinator.switchBackend(to: .icloud)
        try await waitForPass(coordinator)

        #expect(coordinator.engineNamespace == .icloud)
        #expect(coordinator.mirrorContainer === harness.iCloudMirror)
        try harness.expectLocalStateIntact()
        try harness.expectMirrorCarriesState(harness.iCloudMirror)
        #expect(try harness.contentStates(in: harness.iCloudMirror)[laterID]?.isFavorite == true)
        let movies = try ModelContext(harness.catalog).fetch(FetchDescriptor<Movie>())
        #expect(movies.first { $0.id == laterID }?.isFavorite == true)
        // Leaving for iCloud deletes nothing on the server either.
        #expect(harness.pushedTombstones == 0)
        #expect(harness.liveRemoteRecords == liveBeforeReturn)
    }

    @Test func `a lost Lume Cloud store pulls everything again and pushes no deletion`() async throws {
        let harness = try IntegrationHarness()
        defer { _ = ParentalControlsStore.clear() }
        let (lumeCloud, _) = try await harness.fixture.makeJoinedBackend(defaults: harness.defaults)
        let coordinator = harness.makeCoordinator(backend: lumeCloud, lumeCloud: lumeCloud)
        try await runIntegrationPass(coordinator)
        let liveBeforeLoss = harness.liveRemoteRecords
        #expect(liveBeforeLoss > 0)

        try harness.loseMirrorRows(of: lumeCloud.container)
        try await runIntegrationPass(coordinator)

        #expect(harness.fixture.server.feed.requestedSince.last == 0)
        #expect(harness.pushedTombstones == 0)
        #expect(harness.liveRemoteRecords == liveBeforeLoss)
        try harness.expectLocalStateIntact()
        try harness.expectMirrorCarriesState(lumeCloud.container)
        #expect(try ModelContext(lumeCloud.container).fetch(FetchDescriptor<SyncedPlaylist>()).map(\.id) == [harness.playlistID])
    }

    @Test func `a lost Lume Cloud store that can't reach the server keeps every local item`() async throws {
        let harness = try IntegrationHarness()
        defer { _ = ParentalControlsStore.clear() }
        let (lumeCloud, _) = try await harness.fixture.makeJoinedBackend(defaults: harness.defaults)
        let coordinator = harness.makeCoordinator(backend: lumeCloud, lumeCloud: lumeCloud)
        try await runIntegrationPass(coordinator)
        let liveBeforeLoss = harness.liveRemoteRecords
        let feed = harness.fixture.server.feed

        try harness.loseMirrorRows(of: lumeCloud.container)
        feed.changesError.withLock { $0 = { _ in .transport(URLError(.notConnectedToInternet)) } }
        // Twice offline: the first pass resets the bookkeeping and the baseline
        // and refills the mirror from this device, so the second sees no lost
        // store at all.
        try await runIntegrationPass(coordinator)
        try await runIntegrationPass(coordinator)

        try harness.expectLocalStateIntact()
        #expect(harness.pushedTombstones == 0)

        feed.changesError.withLock { $0 = nil }
        try await runIntegrationPass(coordinator)

        #expect(feed.requestedSince.last == 0)
        #expect(harness.pushedTombstones == 0)
        #expect(harness.liveRemoteRecords == liveBeforeLoss)
        try harness.expectLocalStateIntact()
        try harness.expectMirrorCarriesState(lumeCloud.container)
    }

    @Test func `an unfavorite on Lume Cloud reaches the server as a tombstone`() async throws {
        let harness = try IntegrationHarness()
        defer { _ = ParentalControlsStore.clear() }
        let (lumeCloud, _) = try await harness.fixture.makeJoinedBackend(defaults: harness.defaults)
        let coordinator = harness.makeCoordinator(backend: lumeCloud, lumeCloud: lumeCloud)
        try await runIntegrationPass(coordinator)
        let channelKey = try #require(harness.contentStates(in: lumeCloud.container)[harness.favoriteChannelID]).lumeCloudKey
        #expect(try harness.remotePayload(channelKey, of: lumeCloud)?.data["isFavorite"] == .bool(true))

        let context = harness.catalog.mainContext
        let channel = try #require(try context.fetch(FetchDescriptor<LiveStream>()).first { $0.id == harness.favoriteChannelID })
        MediaFavorites.clearFavoriteState(channel)
        try context.save()
        try await runIntegrationPass(coordinator)

        #expect(try harness.remotePayload(channelKey, of: lumeCloud) == nil)
        #expect(harness.pushedTombstones == 1)
        #expect(try harness.contentStates(in: lumeCloud.container)[harness.favoriteChannelID] == nil)
        // The next pass leaves the un-favorite alone: no repair brings it back.
        try await runIntegrationPass(coordinator)
        #expect(try harness.contentStates(in: lumeCloud.container)[harness.favoriteChannelID] == nil)
        let channels = try ModelContext(harness.catalog).fetch(FetchDescriptor<LiveStream>())
        #expect(channels.first { $0.id == harness.favoriteChannelID }?.isFavorite == false)
    }

    @Test func `state cleaned up while its playlist was briefly gone comes back and deletes nothing`() async throws {
        let harness = try IntegrationHarness()
        defer { _ = ParentalControlsStore.clear() }
        let (lumeCloud, _) = try await harness.fixture.makeJoinedBackend(defaults: harness.defaults)
        let coordinator = harness.makeCoordinator(backend: lumeCloud, lumeCloud: lumeCloud)
        try await runIntegrationPass(coordinator)
        let liveBefore = harness.liveRemoteRecords

        // What the engine's cleanup of a briefly absent playlist leaves: no
        // content rows and no baseline, the catalog reset, the bookkeeping
        // still calling every record synced.
        let mirror = ModelContext(lumeCloud.container)
        try mirror.delete(model: UserContentState.self)
        try mirror.save()
        let shadow = CloudSyncShadow(defaults: harness.defaults, namespace: .lumecloud)
        for id in shadow.contentShadowIDs() {
            shadow.setContentShadow(id, nil)
        }
        shadow.persist()
        let context = harness.catalog.mainContext
        for channel in try context.fetch(FetchDescriptor<LiveStream>()) {
            MediaFavorites.clearFavoriteState(channel)
        }
        for movie in try context.fetch(FetchDescriptor<Movie>()) {
            MediaFavorites.clearFavoriteState(movie)
        }
        try context.save()

        // A relaunch: the new engine loads the baseline from the defaults.
        let relaunched = harness.makeCoordinator(backend: lumeCloud, lumeCloud: lumeCloud)
        try await runIntegrationPass(relaunched)

        try harness.expectLocalStateIntact()
        try harness.expectMirrorCarriesState(lumeCloud.container)
        #expect(harness.pushedTombstones == 0)
        #expect(harness.liveRemoteRecords == liveBefore)
    }
}

//
//  CloudSyncShadowNamespaceTests.swift
//  LumeTests
//
//  The shadow baseline is namespaced per sync backend. Reusing one backend's
//  baseline against another backend's (possibly empty) mirror would read every
//  item missing there as a deletion, so a switch resets the target namespace
//  with `resetAll()` before its first reconcile.
//
//  The engine tests touch the keychain PIN, so they live in an extension of the
//  `.serialized` `CloudSyncParentalEngineTests` suite: across suites Swift
//  Testing runs in parallel, and a PIN set here would surface as a phantom push
//  in that suite's counts.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct CloudSyncShadowNamespaceTests {
    @Test func `the two namespaces never see each other's baselines`() {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let iCloud = CloudSyncShadow(defaults: defaults, namespace: .icloud)
        iCloud.setParentalPINShadow(ParentalPINValues(hash: "icloud-hash"))
        iCloud.persist()

        let lumeCloud = CloudSyncShadow(defaults: defaults, namespace: .lumecloud)
        #expect(lumeCloud.parentalPINShadow() == nil)
        lumeCloud.setParentalPINShadow(ParentalPINValues(hash: "lumecloud-hash"))
        lumeCloud.persist()

        #expect(CloudSyncShadow(defaults: defaults, namespace: .icloud).parentalPINShadow()
            == ParentalPINValues(hash: "icloud-hash"))
        #expect(CloudSyncShadow(defaults: defaults, namespace: .lumecloud).parentalPINShadow()
            == ParentalPINValues(hash: "lumecloud-hash"))
        #expect(defaults.data(forKey: "cloudsync.lumecloud.shadow.parentalpin.v1") != nil)
    }

    @Test func `the legacy keys are the iCloud namespace`() throws {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let legacy = try JSONEncoder().encode(ParentalPINValues(hash: "legacy-hash"))
        defaults.set(legacy, forKey: "cloudsync.shadow.parentalpin.v1")

        #expect(CloudSyncShadow(defaults: defaults).parentalPINShadow() == ParentalPINValues(hash: "legacy-hash"))
        #expect(CloudSyncShadow(defaults: defaults, namespace: .icloud).parentalPINShadow()
            == ParentalPINValues(hash: "legacy-hash"))
        #expect(CloudSyncShadow(defaults: defaults, namespace: .lumecloud).parentalPINShadow() == nil)
    }

    @Test func `the default namespace writes the legacy keys`() {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let shadow = CloudSyncShadow(defaults: defaults)
        shadow.setLiveTVPreferencesShadow(LiveTVPreferenceValues(showsFavorites: false, showsRecentlyWatched: true))
        shadow.persist()

        #expect(defaults.data(forKey: "cloudsync.shadow.livetvpreferences.v1") != nil)
        #expect(defaults.data(forKey: "cloudsync.lumecloud.shadow.livetvpreferences.v1") == nil)
    }

    @Test func `resetAll drops the PIN and Live TV baselines from disk at once`() {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let shadow = CloudSyncShadow(defaults: defaults, namespace: .lumecloud)
        shadow.setParentalPINShadow(ParentalPINValues(hash: "h"))
        shadow.setLiveTVPreferencesShadow(LiveTVPreferenceValues(showsFavorites: false, showsRecentlyWatched: false))
        shadow.setCategoryRestrictionShadow("cat", CategoryRestrictionValues())
        shadow.persist()

        shadow.resetAll()

        #expect(shadow.parentalPINShadow() == nil)
        #expect(shadow.liveTVPreferencesShadow() == nil)
        #expect(shadow.categoryRestrictionShadowIDs().isEmpty)
        // No `persist()` in between: a reload straight after must already be empty.
        let reloaded = CloudSyncShadow(defaults: defaults, namespace: .lumecloud)
        #expect(reloaded.parentalPINShadow() == nil)
        #expect(reloaded.liveTVPreferencesShadow() == nil)
        #expect(reloaded.categoryRestrictionShadowIDs().isEmpty)
    }

    @Test func `resetAll on one namespace leaves the other intact`() {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let iCloud = CloudSyncShadow(defaults: defaults, namespace: .icloud)
        iCloud.setParentalPINShadow(ParentalPINValues(hash: "icloud-hash"))
        iCloud.persist()

        CloudSyncShadow(defaults: defaults, namespace: .lumecloud).resetAll()

        #expect(CloudSyncShadow(defaults: defaults, namespace: .icloud).parentalPINShadow()
            == ParentalPINValues(hash: "icloud-hash"))
    }

    @Test func `reset still keeps the PIN and Live TV baselines`() {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let shadow = CloudSyncShadow(defaults: defaults)
        let pin = ParentalPINValues(hash: "h")
        let preferences = LiveTVPreferenceValues(showsFavorites: false, showsRecentlyWatched: false)
        shadow.setParentalPINShadow(pin)
        shadow.setLiveTVPreferencesShadow(preferences)
        shadow.setCategoryRestrictionShadow("cat", CategoryRestrictionValues())

        shadow.reset()

        #expect(shadow.parentalPINShadow() == pin)
        #expect(shadow.liveTVPreferencesShadow() == preferences)
        #expect(shadow.categoryRestrictionShadowIDs().isEmpty)
    }
}

// MARK: - Switching to an empty mirror (engine, in-memory, no CloudKit)

extension CloudSyncParentalEngineTests {
    private static let hiddenRails = LiveTVPreferenceValues(showsFavorites: false, showsRecentlyWatched: false)

    /// A playlist with one favourite movie, a parental PIN in the keychain and
    /// hidden Live TV rails — one item per baseline kind a switch must not lose.
    private func seedLocalState(in catalog: ModelContainer, preferences: UserDefaults) throws -> (playlistID: UUID, movieID: String) {
        let ctx = catalog.mainContext
        let playlist = Playlist(name: "Fictional TV", serverURL: "http://x", username: "u", password: "p")
        ctx.insert(playlist)
        let movieID = "\(playlist.id.uuidString)-movie-1"
        let movie = Movie(id: movieID, streamId: 1, name: "Film")
        movie.isFavorite = true
        ctx.insert(movie)
        try ctx.save()
        ParentalControlsStore.save(pin: "1234")
        LiveTVRailSettings.store(Self.hiddenRails, in: preferences)
        return (playlist.id, movieID)
    }

    /// Baselines a `.lumecloud` namespace against a mirror, then returns a fresh
    /// empty mirror — the rejoin case, where the old Lume Cloud mirror is wiped
    /// while its shadow is still on disk.
    private func staleLumeCloudShadow(
        catalog: ModelContainer, defaults: UserDefaults, preferences: UserDefaults
    ) async throws -> CloudSyncShadow {
        let previous = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
        let shadow = CloudSyncShadow(defaults: defaults, namespace: .lumecloud)
        _ = await CloudSyncEngine(
            catalogContainer: catalog, cloudContainer: previous, shadow: shadow, preferences: preferences
        ).reconcile()
        #expect(!shadow.playlistShadowIDs().isEmpty)
        #expect(shadow.parentalPINShadow() != nil)
        return CloudSyncShadow(defaults: defaults, namespace: .lumecloud)
    }

    @Test func `switching to an empty mirror after resetAll pushes everything and deletes nothing`() async throws {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let preferences = LumeCloudBackendFixture.makeDefaults()
        defer { ParentalControlsStore.clear() }
        let catalog = try makeTestContainer()
        let (playlistID, movieID) = try seedLocalState(in: catalog, preferences: preferences)

        let iCloudShadow = CloudSyncShadow(defaults: defaults, namespace: .icloud)
        _ = try await CloudSyncEngine(
            catalogContainer: catalog, cloudContainer: makeICloudMirrorTestContainer(),
            shadow: iCloudShadow, preferences: preferences
        ).reconcile()

        let target = try await staleLumeCloudShadow(catalog: catalog, defaults: defaults, preferences: preferences)
        target.resetAll()
        let mirror = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
        let result = await CloudSyncEngine(
            catalogContainer: catalog, cloudContainer: mirror, shadow: target, preferences: preferences
        ).reconcile()

        // Nothing pulled, so no local deletion; one push per item, so no cloud
        // deletion either (a nil push isn't counted).
        #expect(result.playlistsPulled == 0)
        #expect(result.contentPulled == 0)
        #expect(result.parentalPulled == 0)
        #expect(result.preferencesPulled == 0)
        #expect(result.playlistsPushed == 1)
        #expect(result.contentPushed == 1)
        #expect(result.parentalPushed == 1)
        #expect(result.preferencesPushed == 1)

        let local = ModelContext(catalog)
        #expect(try local.fetch(FetchDescriptor<Playlist>()).map(\.id) == [playlistID])
        let movie = try local.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieID })).first
        #expect(movie?.isFavorite == true)
        #expect(ParentalControlsStore.verify(pin: "1234"))
        #expect(LiveTVRailSettings.storedValues(in: preferences) == Self.hiddenRails)

        let cloud = ModelContext(mirror)
        #expect(try cloud.fetch(FetchDescriptor<SyncedPlaylist>()).map(\.id) == [playlistID])
        #expect(try cloud.fetch(FetchDescriptor<UserContentState>()).first?.isFavorite == true)
        #expect(try cloud.fetch(FetchDescriptor<SyncedParentalPIN>()).count == 1)
        #expect(try cloud.fetch(FetchDescriptor<SyncedLiveTVPreferences>()).count == 1)

        // The iCloud baseline survives for a later switch back.
        let iCloudReloaded = CloudSyncShadow(defaults: defaults, namespace: .icloud)
        #expect(iCloudReloaded.playlistShadowIDs() == [playlistID.uuidString])
        #expect(iCloudReloaded.parentalPINShadow() != nil)
    }

    @Test func `without resetAll a stale baseline against an empty mirror deletes local data`() async throws {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let preferences = LumeCloudBackendFixture.makeDefaults()
        defer { ParentalControlsStore.clear() }
        let catalog = try makeTestContainer()
        _ = try seedLocalState(in: catalog, preferences: preferences)

        let stale = try await staleLumeCloudShadow(catalog: catalog, defaults: defaults, preferences: preferences)
        let mirror = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
        _ = await CloudSyncEngine(
            catalogContainer: catalog, cloudContainer: mirror, shadow: stale, preferences: preferences
        ).reconcile()

        // The failure `resetAll()` exists to prevent: every item reads as
        // deleted on the other side and is removed locally.
        #expect(try ModelContext(catalog).fetch(FetchDescriptor<Playlist>()).isEmpty)
        #expect(!ParentalControlsStore.isSet)
        #expect(LiveTVRailSettings.storedValues(in: preferences) == nil)
    }
}

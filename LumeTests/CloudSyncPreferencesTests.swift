//
//  CloudSyncPreferencesTests.swift
//  LumeTests
//
//  Covers the Live TV rail switches (Settings › Live TV › Categories) syncing
//  over CloudKit: UserDefaults is the local store of record, the
//  `SyncedLiveTVPreferences` singleton carries the value between devices.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct LiveTVRailSettingsTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "livetv.rail.test.\(UUID().uuidString)")!
    }

    @Test func `an untouched device has no stored value`() {
        #expect(LiveTVRailSettings.storedValues(in: freshDefaults()) == nil)
    }

    @Test func `one written switch reads the other as its default`() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: LiveTVRailSettings.showsRecentlyWatchedKey)
        #expect(LiveTVRailSettings.storedValues(in: defaults)
            == LiveTVPreferenceValues(showsFavorites: true, showsRecentlyWatched: false))
    }

    @Test func `storing nil returns both switches to their defaults`() {
        let defaults = freshDefaults()
        LiveTVRailSettings.store(LiveTVPreferenceValues(showsFavorites: false, showsRecentlyWatched: false), in: defaults)
        LiveTVRailSettings.store(nil, in: defaults)
        #expect(LiveTVRailSettings.storedValues(in: defaults) == nil)
    }

    @Test func `a conflict resolves cloud-wins`() {
        let verdict = CloudSyncMerge.reconcile(
            local: LiveTVPreferenceValues(showsFavorites: false, showsRecentlyWatched: true),
            cloud: LiveTVPreferenceValues(showsFavorites: true, showsRecentlyWatched: false),
            shadow: LiveTVPreferenceValues(showsFavorites: true, showsRecentlyWatched: true),
            mergeConflict: LiveTVPreferenceValues.mergeConflict
        )
        #expect(verdict == .writeBoth(LiveTVPreferenceValues(showsFavorites: true, showsRecentlyWatched: false)))
    }
}

@MainActor
struct CloudSyncPreferencesEngineTests {
    private let hidden = LiveTVPreferenceValues(showsFavorites: false, showsRecentlyWatched: true)

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "cloudsync.preferences.test.\(UUID().uuidString)")!
    }

    private func records(in ctx: ModelContext) throws -> [SyncedLiveTVPreferences] {
        try ctx.fetch(FetchDescriptor<SyncedLiveTVPreferences>())
    }

    @Test func `an untouched device exports nothing`() async throws {
        let container = try makeProfileTestContainer()
        let engine = CloudSyncEngine(
            container: container, shadow: CloudSyncShadow(defaults: freshDefaults()), preferences: freshDefaults()
        )

        let result = await engine.reconcile()

        #expect(result.preferencesPushed == 0)
        #expect(try records(in: container.mainContext).isEmpty)
    }

    @Test func `a local change exports the singleton record`() async throws {
        let container = try makeProfileTestContainer()
        let preferences = freshDefaults()
        LiveTVRailSettings.store(hidden, in: preferences)
        let engine = CloudSyncEngine(
            container: container, shadow: CloudSyncShadow(defaults: freshDefaults()), preferences: preferences
        )

        let result = await engine.reconcile()

        #expect(result.preferencesPushed == 1)
        let stored = try records(in: container.mainContext)
        #expect(stored.count == 1)
        #expect(stored.first?.showsFavorites == false)
        #expect(stored.first?.showsRecentlyWatched == true)

        let second = await engine.reconcile()
        #expect(second.preferencesPushed == 0)
        #expect(second.preferencesPulled == 0)
    }

    @Test func `a fresh device adopts the cloud value instead of pushing its defaults`() async throws {
        let container = try makeProfileTestContainer()
        container.mainContext.insert(SyncedLiveTVPreferences(showsFavorites: false, showsRecentlyWatched: true))
        try container.mainContext.save()
        let preferences = freshDefaults()
        let engine = CloudSyncEngine(
            container: container, shadow: CloudSyncShadow(defaults: freshDefaults()), preferences: preferences
        )

        let result = await engine.reconcile()

        #expect(result.preferencesPulled == 1)
        #expect(LiveTVRailSettings.storedValues(in: preferences) == hidden)
    }

    @Test func `a later local edit updates the existing record`() async throws {
        let container = try makeProfileTestContainer()
        let preferences = freshDefaults()
        let engine = CloudSyncEngine(
            container: container, shadow: CloudSyncShadow(defaults: freshDefaults()), preferences: preferences
        )
        LiveTVRailSettings.store(hidden, in: preferences)
        await engine.reconcile()

        LiveTVRailSettings.store(LiveTVPreferenceValues(showsFavorites: true, showsRecentlyWatched: false), in: preferences)
        let result = await engine.reconcile()

        #expect(result.preferencesPushed == 1)
        let stored = try records(in: container.mainContext)
        #expect(stored.count == 1)
        #expect(stored.first?.showsFavorites == true)
        #expect(stored.first?.showsRecentlyWatched == false)
    }

    @Test func `duplicate singletons collapse to the newest`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        ctx.insert(SyncedLiveTVPreferences(showsFavorites: true, showsRecentlyWatched: true, updatedAt: .distantPast))
        ctx.insert(SyncedLiveTVPreferences(showsFavorites: false, showsRecentlyWatched: true, updatedAt: .now))
        try ctx.save()
        let preferences = freshDefaults()
        let engine = CloudSyncEngine(
            container: container, shadow: CloudSyncShadow(defaults: freshDefaults()), preferences: preferences
        )

        await engine.reconcile()

        #expect(try records(in: ctx).count == 1)
        #expect(LiveTVRailSettings.storedValues(in: preferences) == hidden)
    }
}

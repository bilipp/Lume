//
//  CloudSyncSportsTests.swift
//  LumeTests
//
//  Covers the sports-follow reconcile: duplicate (key, profile) rows CloudKit
//  surfaced collapse on reconcile, follows for different profiles are kept
//  apart, and a deleted profile's follows are purged. `SyncedSportsFollow` has
//  no local counterpart, so the reconcile is a pure cloud-side dedupe.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CloudSyncSportsTests {
    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "cloudsync.sports.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    @Test func `duplicate follow rows collapse to the newest on reconcile`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let profile = UUID()
        ctx.insert(SyncedSportsFollow(
            key: "espn:soccer/ger.1", kindRaw: "league", profileID: profile,
            sortOrder: 1, updatedAt: Date(timeIntervalSince1970: 1000)
        ))
        ctx.insert(SyncedSportsFollow(
            key: "espn:soccer/ger.1", kindRaw: "league", profileID: profile,
            sortOrder: 5, updatedAt: Date(timeIntervalSince1970: 2000)
        ))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        let remaining = try ctx.fetch(FetchDescriptor<SyncedSportsFollow>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.sortOrder == 5)
        #expect(result.sportsFollowsKept == 1)
        #expect(result.sportsFollowsDeduped == 1)
    }

    @Test func `the same follow under two profiles is not a duplicate`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        ctx.insert(SyncedSportsFollow(key: "espn:soccer/ger.1", kindRaw: "league", profileID: UUID()))
        ctx.insert(SyncedSportsFollow(key: "espn:soccer/ger.1", kindRaw: "league", profileID: UUID()))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        let remaining = try ctx.fetch(FetchDescriptor<SyncedSportsFollow>())
        #expect(remaining.count == 2)
        #expect(result.sportsFollowsKept == 2)
        #expect(result.sportsFollowsDeduped == 0)
    }

    @Test func `purging a profile deletes only its follows`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let profileA = UUID()
        let profileB = UUID()
        ctx.insert(SyncedSportsFollow(key: "espn:soccer/ger.1", kindRaw: "league", profileID: profileA))
        ctx.insert(SyncedSportsFollow(key: "espn:soccer/eng.1", kindRaw: "league", profileID: profileB))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        try await engine.purgeProfileData(profileA)

        let remaining = try ctx.fetch(FetchDescriptor<SyncedSportsFollow>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.profileID == profileB)
    }
}

//
//  CloudSyncParentalTests.swift
//  LumeTests
//
//  Covers the parental-control reconcile: the PIN and per-category restrictions
//  syncing over CloudKit rather than staying on whichever device set them.
//
//  The restriction tests are the bulk of this file and touch no keychain. The
//  single PIN test does, so the suite is `.serialized`: `ParentalControlsStore`
//  talks to the process-wide keychain, and a PIN left set by one test would be
//  picked up by another test's reconcile pass running concurrently.
//
//  `.serialized` alone isn't enough, though: the keychain outlives the *process*,
//  so a PIN stranded by an interrupted run (or by manual testing on the same
//  simulator) would still be there on the next one — and because `parentalPushed`
//  counts the PIN and the restrictions together, it would add a phantom push to
//  every count assertion below. Hence the per-test `init` that clears it.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

// MARK: - Merge policy

struct ParentalMergePolicyTests {
    @Test func `PIN conflict resolves cloud-wins`() {
        let verdict = CloudSyncMerge.reconcile(
            local: ParentalPINValues(hash: "local-hash"),
            cloud: ParentalPINValues(hash: "cloud-hash"),
            shadow: ParentalPINValues(hash: "old-hash"),
            mergeConflict: ParentalPINValues.mergeConflict
        )
        #expect(verdict == .writeBoth(ParentalPINValues(hash: "cloud-hash")))
    }

    @Test func `turning the PIN off pushes a deletion rather than re-arming it`() {
        // The whole reason for a shadow: without the baseline, "no local PIN"
        // would be indistinguishable from "this device never had one", and the
        // cloud copy would be pulled straight back down.
        let verdict = CloudSyncMerge.reconcile(
            local: nil,
            cloud: ParentalPINValues(hash: "h"),
            shadow: ParentalPINValues(hash: "h"),
            mergeConflict: ParentalPINValues.mergeConflict
        )
        #expect(verdict == .pushToCloud(nil))
    }

    @Test func `a restriction is presence, so lifting one merges as a deletion`() {
        let verdict = CloudSyncMerge.reconcile(
            local: nil,
            cloud: CategoryRestrictionValues(),
            shadow: CategoryRestrictionValues(),
            mergeConflict: CategoryRestrictionValues.mergeConflict
        )
        #expect(verdict == .pushToCloud(nil))
    }

    @Test func `two devices locking the same category is not a conflict`() {
        let verdict = CloudSyncMerge.reconcile(
            local: CategoryRestrictionValues(),
            cloud: CategoryRestrictionValues(),
            shadow: nil,
            mergeConflict: CategoryRestrictionValues.mergeConflict
        )
        #expect(verdict == .pushToCloud(CategoryRestrictionValues()))
    }
}

// MARK: - Engine integration (in-memory, no CloudKit)

@MainActor
@Suite(.serialized)
struct CloudSyncParentalEngineTests {
    /// Runs before every test in the suite (Swift Testing instantiates the suite
    /// per test): start from a keychain with no PIN, so the shared
    /// `parentalPushed` counter reflects only what the test itself set up.
    init() {
        ParentalControlsStore.clear()
    }

    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "cloudsync.parental.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    /// Seeds a playlist with one category, returning both. The category id embeds
    /// the playlist UUID, which is what makes a record addressable across devices.
    private func seedCategory(in ctx: ModelContext, restricted: Bool) throws -> (playlist: Playlist, category: Lume.Category) {
        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        ctx.insert(playlist)
        let category = Lume.Category(apiId: "9", name: "Adults", parentId: 0, type: .live, playlist: playlist)
        category.isRestricted = restricted
        ctx.insert(category)
        try ctx.save()
        return (playlist, category)
    }

    /// Re-reads a category's restriction from the store rather than trusting the
    /// caller's object. The engine writes through its own `ModelContext`, so an
    /// instance already materialized in `mainContext` can still hold the old
    /// value — the same reason the other engine tests re-fetch their assertions.
    private func isRestricted(_ id: String, in ctx: ModelContext) throws -> Bool {
        try ctx.fetch(FetchDescriptor<Lume.Category>(predicate: #Predicate { $0.id == id })).first?.isRestricted ?? false
    }

    @Test func `a locally locked category exports a restriction record`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let (_, category) = try seedCategory(in: ctx, restricted: true)

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        #expect(result.parentalPushed == 1)
        let records = try ctx.fetch(FetchDescriptor<SyncedCategoryRestriction>())
        #expect(records.count == 1)
        #expect(records.first?.categoryID == category.id)
        #expect(records.first?.isRestricted == true)
    }

    @Test func `an unlocked category exports nothing`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        _ = try seedCategory(in: ctx, restricted: false)

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await engine.reconcile()

        // Presence is the restriction — an unlocked category must cost no record.
        #expect(try ctx.fetch(FetchDescriptor<SyncedCategoryRestriction>()).isEmpty)
    }

    @Test func `a cloud restriction locks the category on this device`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let (_, category) = try seedCategory(in: ctx, restricted: false)
        ctx.insert(SyncedCategoryRestriction(categoryID: category.id))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        #expect(result.parentalPulled == 1)
        #expect(try isRestricted(category.id, in: ctx))
    }

    @Test func `a cloud restriction stays pending until its category exists`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let shadow = freshShadow()

        // The playlist exists (so the record isn't garbage-collected as orphaned)
        // but its catalog hasn't been fetched yet, so the category is absent.
        let playlist = Playlist(name: "Remote", serverURL: "http://r", username: "u", password: "p")
        ctx.insert(playlist)
        let categoryID = "\(playlist.id.uuidString)-live-9"
        ctx.insert(SyncedCategoryRestriction(categoryID: categoryID))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: shadow)
        let first = await engine.reconcile()
        #expect(first.parentalPending == 1)
        #expect(first.parentalPulled == 0)

        // The catalog lands; the deferred restriction now applies.
        let category = Lume.Category(apiId: "9", name: "Adults", parentId: 0, type: .live, playlist: playlist)
        ctx.insert(category)
        try ctx.save()
        #expect(category.id == categoryID)

        let second = await engine.reconcile()
        #expect(second.parentalPulled == 1)
        #expect(try isRestricted(categoryID, in: ctx))
    }

    @Test func `unlocking a category deletes its cloud restriction`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let shadow = freshShadow()
        let (_, category) = try seedCategory(in: ctx, restricted: true)

        let engine = CloudSyncEngine(container: container, shadow: shadow)
        _ = await engine.reconcile()
        #expect(try ctx.fetch(FetchDescriptor<SyncedCategoryRestriction>()).count == 1)

        // The parent unlocks it. The shadow is what lets this read as a deletion
        // rather than as "this device just hasn't heard about it yet".
        category.isRestricted = false
        try ctx.save()

        _ = await engine.reconcile()
        #expect(try ctx.fetch(FetchDescriptor<SyncedCategoryRestriction>()).isEmpty)
    }

    @Test func `a restriction whose playlist is gone is garbage-collected`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        // No playlist, local or cloud, owns this id.
        ctx.insert(SyncedCategoryRestriction(categoryID: "\(UUID().uuidString)-live-9"))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        #expect(try ctx.fetch(FetchDescriptor<SyncedCategoryRestriction>()).isEmpty)
        // Garbage collection is not a pull, and must not be reported as pending —
        // a pending record would be retried on every pass forever.
        #expect(result.parentalPending == 0)
    }

    @Test func `a local PIN exports to the cloud and a cloud PIN lands in the keychain`() async throws {
        ParentalControlsStore.clear()
        defer { ParentalControlsStore.clear() }

        let container = try makeProfileTestContainer()
        let ctx = container.mainContext

        // Push: a PIN set on this device reaches the cloud as a hash.
        ParentalControlsStore.save(pin: "1234")
        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await engine.reconcile()

        let records = try ctx.fetch(FetchDescriptor<SyncedParentalPIN>())
        #expect(records.count == 1)
        #expect(records.first?.pinHash.isEmpty == false)
        #expect(records.first?.pinHash != "1234") // never the PIN itself

        // Pull: a fresh device with the same cloud record adopts the PIN, so its
        // gates arm without the parent re-entering anything.
        ParentalControlsStore.clear()
        #expect(!ParentalControlsStore.isSet)

        let fresh = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await fresh.reconcile()

        #expect(ParentalControlsStore.isSet)
        #expect(ParentalControlsStore.verify(pin: "1234"))
        #expect(!ParentalControlsStore.verify(pin: "9999"))
    }
}

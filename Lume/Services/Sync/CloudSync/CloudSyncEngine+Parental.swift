//
//  CloudSyncEngine+Parental.swift
//  Lume
//
//  Reconciles the two pieces of parental-control state that were previously
//  stranded on whichever device set them: the PIN and per-category restrictions
//  (`Category.isRestricted`, the "locked" toggle in Content Management).
//
//  Both matter together. Profiles and their `isChild` flag already sync, so a
//  second device would faithfully render the kids profile a parent configured
//  and then enforce none of it: every gate in `ParentalControls` is guarded on
//  `isPINSet`, and every hidden-from-kids decision reads `isRestricted`. A device
//  missing both showed a locked-down-looking profile with nothing behind it.
//
//  Unlike `UserContentState`, neither record is profile-scoped. That is the whole
//  point: a restriction is a rule a parent sets *about* a child profile, and the
//  PIN is what stops a child leaving one. Filing either under "whichever profile
//  was active when it was set" would make it silently inert exactly when the
//  child's profile is the active one.
//
//  Mechanically this is the same three-way merge over a shadow baseline as every
//  other pass (see `CloudSyncMerge`), which is what lets "the parent turned the
//  PIN off" and "this device never had a PIN" be told apart — a distinction a
//  two-way mirror cannot make, and one that decides whether a device re-arms a
//  PIN the parent deliberately removed.
//

import Foundation
import OSLog
import SwiftData

extension CloudSyncEngine {
    /// Three-way-merges the PIN and category restrictions with their cloud
    /// mirrors. Runs inside `reconcile()`, so it inherits the
    /// `LocalCatalogReadiness` guard — an emptied catalog can never push mass
    /// restriction deletions to iCloud.
    func reconcileParentalControls(livePrefixes: Set<String>, into result: inout CloudSyncReconcileResult) throws {
        try reconcileParentalPIN(into: &result)
        try reconcileCategoryRestrictions(livePrefixes: livePrefixes, into: &result)
    }

    // MARK: - PIN

    private func reconcileParentalPIN(into result: inout CloudSyncReconcileResult) throws {
        let local: ParentalPINValues?
        switch ParentalControlsStore.storedHash() {
        case let .hash(hash):
            local = ParentalPINValues(hash: hash)
        case .notSet:
            local = nil
        case .unavailable:
            // The keychain refused the read — this pass is running with the
            // device locked (the pre-suspension flush fires as the screen locks,
            // and a CloudKit push can wake the process). "Couldn't look" is not
            // "the parent removed the PIN": merging on it would push a deletion
            // and clear the PIN on every other device. Leave the shadow and both
            // stores alone; the next unlocked pass reconciles it.
            Logger.sync.info("Parental PIN keychain unreadable (device locked?) — skipping PIN merge this pass")
            result.parentalPending += 1
            return
        }

        let mirror = try fetchParentalPINMirror()
        let verdict = CloudSyncMerge.reconcile(
            local: local,
            cloud: mirror.map { ParentalPINValues(hash: $0.pinHash) },
            shadow: shadow.parentalPINShadow(),
            mergeConflict: ParentalPINValues.mergeConflict
        )
        applyPINVerdict(verdict, mirror: mirror, into: &result)
    }

    private func applyPINVerdict(
        _ verdict: MergeVerdict<ParentalPINValues>,
        mirror: SyncedParentalPIN?,
        into result: inout CloudSyncReconcileResult
    ) {
        switch verdict {
        case .noChange:
            break
        case let .pushToCloud(value):
            applyPINToCloud(value, mirror: mirror)
            if value != nil { result.parentalPushed += 1 }
            shadow.setParentalPINShadow(value)
        case let .pullToLocal(value):
            guard applyPINToLocal(value) else {
                result.parentalPending += 1
                return
            }
            if value != nil { result.parentalPulled += 1 }
            shadow.setParentalPINShadow(value)
        case let .writeBoth(value):
            guard applyPINToLocal(value) else {
                result.parentalPending += 1
                return
            }
            applyPINToCloud(value, mirror: mirror)
            result.parentalPushed += 1
            shadow.setParentalPINShadow(value)
        }
    }

    /// Writes the merged PIN into the keychain, which stays the local store of
    /// record. A nil value is the parent turning the PIN off on another device.
    ///
    /// Returns false when the keychain refused the write, so the caller leaves the
    /// shadow untouched. Baselining a value the keychain never took would make
    /// the next pass read the missing hash as a local deletion and push it —
    /// wiping the PIN on every device from one failed write.
    private func applyPINToLocal(_ value: ParentalPINValues?) -> Bool {
        guard let value else { return ParentalControlsStore.clear() }
        return ParentalControlsStore.store(hash: value.hash)
    }

    private func applyPINToCloud(_ value: ParentalPINValues?, mirror: SyncedParentalPIN?) {
        guard let value else {
            if let mirror { cloudContext.delete(mirror) }
            return
        }
        guard let mirror else {
            cloudContext.insert(SyncedParentalPIN(pinHash: value.hash))
            return
        }
        // Only stamp `updatedAt` on a real change: it is the dedupe tie-break,
        // and bumping it every pass would make an untouched record look newer
        // than a genuinely newer one from another device.
        guard mirror.pinHash != value.hash else { return }
        mirror.pinHash = value.hash
        mirror.updatedAt = Date()
    }

    // MARK: - Category restrictions

    private func reconcileCategoryRestrictions(livePrefixes: Set<String>, into result: inout CloudSyncReconcileResult) throws {
        let localIDs = try fetchRestrictedCategoryIDs()
        let mirrorsByID = try fetchCategoryRestrictionMirrors()

        // Union of all three sources, so a restriction lifted on either side is
        // still visited — an id that vanished locally is exactly what the shadow
        // is there to remember.
        var ids = localIDs.union(mirrorsByID.keys)
        ids.formUnion(shadow.categoryRestrictionShadowIDs())
        guard !ids.isEmpty else { return }

        // One chunked `IN` fetch for every id this pass touches, rather than a
        // single-row fetch per id — the same batching the content pass was
        // rewritten to use (`fetchCatalogModels`).
        let categories = try fetchCatalogModels(byKind: [.category: Array(ids)])

        for id in ids {
            let category = categories[id] as? Category
            // Garbage-collect restrictions whose owning playlist is gone on both
            // sides, exactly as the content pass does. Without this, a record for
            // a deleted category can never be applied (its `Category` is gone) and
            // so would be reported pending on every pass, forever.
            guard livePrefixes.contains(String(id.prefix(36))) else {
                if let mirror = mirrorsByID[id] { cloudContext.delete(mirror) }
                // Clear the orphan too, mirroring `resetLocalContent`: a category
                // row that outlived its playlist would otherwise keep feeding
                // `MainTabView`'s restricted set forever.
                if let category, category.isRestricted { category.isRestricted = false }
                shadow.setCategoryRestrictionShadow(id, nil)
                continue
            }

            let verdict = CloudSyncMerge.reconcile(
                local: localIDs.contains(id) ? CategoryRestrictionValues() : nil,
                // A record that somehow says `false` reads as no restriction at
                // all — presence is the restriction, so the two must agree.
                cloud: mirrorsByID[id].flatMap { $0.isRestricted ? CategoryRestrictionValues() : nil },
                shadow: shadow.categoryRestrictionShadow(id),
                mergeConflict: CategoryRestrictionValues.mergeConflict
            )
            applyRestrictionVerdict(verdict, id: id, category: category, mirror: mirrorsByID[id], into: &result)
        }
    }

    private func applyRestrictionVerdict(
        _ verdict: MergeVerdict<CategoryRestrictionValues>,
        id: String,
        category: Category?,
        mirror: SyncedCategoryRestriction?,
        into result: inout CloudSyncReconcileResult
    ) {
        switch verdict {
        case .noChange:
            break
        case let .pushToCloud(value):
            applyRestrictionToCloud(value, id: id, mirror: mirror)
            if value != nil { result.parentalPushed += 1 }
            shadow.setCategoryRestrictionShadow(id, value)
        case let .pullToLocal(value):
            guard applyRestrictionToLocal(value, category: category) else {
                result.parentalPending += 1
                return
            }
            if value != nil { result.parentalPulled += 1 }
            shadow.setCategoryRestrictionShadow(id, value)
        case let .writeBoth(value):
            guard applyRestrictionToLocal(value, category: category) else {
                result.parentalPending += 1
                return
            }
            applyRestrictionToCloud(value, id: id, mirror: mirror)
            result.parentalPushed += 1
            shadow.setCategoryRestrictionShadow(id, value)
        }
    }

    /// Returns false — leaving the change pending, shadow untouched — when the
    /// category hasn't synced to this device yet, matching how content state
    /// waits for its catalog item.
    private func applyRestrictionToLocal(_ value: CategoryRestrictionValues?, category: Category?) -> Bool {
        guard let category else {
            // Applying a restriction has to wait for the catalog. *Lifting* one
            // has nothing to clear, so it is already satisfied — reporting it
            // pending would keep the id alive in the shadow forever.
            return value == nil
        }
        category.isRestricted = value != nil
        return true
    }

    private func applyRestrictionToCloud(_ value: CategoryRestrictionValues?, id: String, mirror: SyncedCategoryRestriction?) {
        guard value != nil else {
            if let mirror { cloudContext.delete(mirror) }
            return
        }
        guard let mirror else {
            cloudContext.insert(SyncedCategoryRestriction(categoryID: id))
            return
        }
        guard !mirror.isRestricted else { return }
        mirror.isRestricted = true
        mirror.updatedAt = Date()
    }

    // MARK: - Fetches

    /// The PIN mirror, collapsing any duplicate singletons two devices inserted
    /// before they converged (CloudKit cannot enforce uniqueness).
    private func fetchParentalPINMirror() throws -> SyncedParentalPIN? {
        var winner: SyncedParentalPIN?
        for record in try cloudContext.fetch(FetchDescriptor<SyncedParentalPIN>()) {
            winner = dedupe(record, against: winner, updatedAt: \.updatedAt)
        }
        return winner
    }

    private func fetchCategoryRestrictionMirrors() throws -> [String: SyncedCategoryRestriction] {
        var map: [String: SyncedCategoryRestriction] = [:]
        for record in try cloudContext.fetch(FetchDescriptor<SyncedCategoryRestriction>()) {
            map[record.categoryID] = dedupe(record, against: map[record.categoryID], updatedAt: \.updatedAt)
        }
        return map
    }

    /// Ids of the locally-restricted categories. `isRestricted` is indexed, so
    /// this seeks the handful of locked rows instead of scanning every category.
    private func fetchRestrictedCategoryIDs() throws -> Set<String> {
        let categories = try catalogContext.fetch(FetchDescriptor<Category>(
            predicate: #Predicate { $0.isRestricted }
        ))
        return Set(categories.map(\.id))
    }
}

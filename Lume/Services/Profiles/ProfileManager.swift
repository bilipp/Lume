import CoreData
import Foundation
import OSLog
import SwiftData
import SwiftUI

/// UI-facing facade for user profiles. Owns the active-profile selection and the
/// profile roster's lifecycle; delegates the heavy, off-main store work (catalog
/// re-projection on switch, legacy migration, content purge) to
/// `CloudSyncCoordinator`/`CloudSyncEngine`, which already run on a background
/// `ModelContext`.
///
/// Simple `UserProfile` CRUD happens directly on the main context — those are
/// cheap single-row writes and SwiftData merges the engine's background saves
/// back into it, so `@Query`-driven UI stays consistent.
@MainActor
@Observable
final class ProfileManager {
    private(set) var activeProfileID: UUID {
        didSet { activeProfile = profile(with: activeProfileID) }
    }

    /// Cached active profile, refreshed whenever `activeProfileID` changes. Avoids
    /// a SwiftData fetch on every SwiftUI body that reads it (the switcher chip
    /// lives in toolbars and the settings screen, which re-render often).
    private(set) var activeProfile: UserProfile?

    /// Whether the active profile is a child — drives content restriction across
    /// the browse, Home and Search surfaces.
    var activeProfileIsChild: Bool {
        activeProfile?.isChild ?? false
    }

    /// True once launch bootstrap has resolved the active profile and claimed any
    /// legacy records. The switcher waits on this before offering a switch.
    private(set) var isReady = false
    /// True while a profile switch is re-projecting the catalog — the UI blocks
    /// interaction so a half-projected catalog is never shown.
    private(set) var isSwitching = false

    /// The profile roster the UI reads (instead of a `@Query`). `UserProfile`
    /// lives in the cloud store — a separate container the browse `@Query`s don't
    /// bind to — so the profile views can't query it directly; they observe this
    /// instead. Refreshed after each mutation and on CloudKit remote-change. Field
    /// edits to existing profiles propagate via the `@Model`'s own observation, so
    /// this array only changes when the *set* of profiles does.
    private(set) var profiles: [UserProfile] = []

    /// Holds `UserProfile` (the CloudKit-mirrored store); all profile CRUD runs on
    /// its main context.
    private let cloudContainer: ModelContainer
    /// The local-only catalog store. Used only to flush pending catalog edits
    /// before a profile switch, so the engine's background pass reads current state.
    private let catalogContainer: ModelContainer
    private let coordinator: CloudSyncCoordinator
    /// Process-lifetime; never removed (this manager lives for the whole app).
    private var remoteChangeObserver: NSObjectProtocol?

    init(catalogContainer: ModelContainer, cloudContainer: ModelContainer, coordinator: CloudSyncCoordinator) {
        self.catalogContainer = catalogContainer
        self.cloudContainer = cloudContainer
        self.coordinator = coordinator
        activeProfileID = ActiveProfileStore.current ?? UserProfile.defaultProfileID
        // `didSet` doesn't fire for the in-init assignment above, so seed the
        // cache directly (same single-row fetch shape) — keeps a profile resolved
        // on a prior launch available before `bootstrap()` runs.
        let resolvedID = activeProfileID
        var descriptor = FetchDescriptor<UserProfile>(predicate: #Predicate { $0.id == resolvedID })
        descriptor.fetchLimit = 1
        activeProfile = (try? cloudContainer.mainContext.fetch(descriptor))?.first
        profiles = allProfiles()
        // `UserProfile` syncs via CloudKit; refresh the roster when a remote change
        // (a profile added/removed on another device) lands. Only the cloud store
        // posts this — the catalog store is local-only. Cheap (a few rows) and
        // guarded, so the constant import churn doesn't re-render the profile UI.
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshProfiles() }
        }
    }

    /// `UserProfile` lives in the cloud store, so all profile CRUD runs on the
    /// cloud container's main context.
    private var context: ModelContext {
        cloudContainer.mainContext
    }

    // MARK: - Launch

    /// Ensure a default profile exists, resolve the active profile and claim any
    /// pre-profiles content records. Run once at launch, before the first sync.
    func bootstrap() async {
        let result = await coordinator.bootstrapProfiles(
            preferredActiveID: ActiveProfileStore.current,
            defaultName: String(localized: "Profile 1", comment: "Name of the automatically-created first profile")
        )
        ActiveProfileStore.current = result.activeProfileID
        activeProfileID = result.activeProfileID
        isReady = true
        refreshProfiles()
    }

    // MARK: - Queries

    func allProfiles() -> [UserProfile] {
        let descriptor = FetchDescriptor<UserProfile>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Re-read the roster from the cloud store, reassigning `profiles` only when
    /// the *set* changed — so CloudKit's constant remote-change churn doesn't
    /// needlessly re-render the profile UI (field edits propagate via `@Model`).
    private func refreshProfiles() {
        let latest = allProfiles()
        if latest.map(\.persistentModelID) != profiles.map(\.persistentModelID) {
            profiles = latest
        }
    }

    func profile(with id: UUID) -> UserProfile? {
        var descriptor = FetchDescriptor<UserProfile>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Mutations

    @discardableResult
    func createProfile(name: String, symbolName: String, color: ProfileColor, isChild: Bool = false) -> UserProfile {
        let profile = UserProfile(
            name: name,
            symbolName: symbolName,
            colorRaw: color.rawValue,
            sortOrder: (try? context.fetchCount(FetchDescriptor<UserProfile>())) ?? 0,
            isChild: isChild
        )
        context.insert(profile)
        try? context.save()
        refreshProfiles()
        return profile
    }

    func updateProfile(_ profile: UserProfile, name: String, symbolName: String, color: ProfileColor, isChild: Bool) {
        profile.name = name
        profile.symbolName = symbolName
        profile.colorRaw = color.rawValue
        profile.isChild = isChild
        profile.updatedAt = Date()
        try? context.save()
    }

    /// Re-project the catalog onto another profile's saved state.
    func switchProfile(to id: UUID) async {
        guard id != activeProfileID, !isSwitching else { return }
        let from = activeProfileID
        isSwitching = true
        // Flush any pending catalog edits (e.g. a favorite toggled moments ago,
        // not yet autosaved) so the engine — which reads the catalog through its
        // own background context — exports the outgoing profile's *current* state
        // rather than a stale snapshot. This flushes the CATALOG main context;
        // profile rows live in the separate cloud store.
        try? catalogContainer.mainContext.save()
        // The engine commits `ActiveProfileStore.current = id` atomically with
        // the projection swap (see `CloudSyncEngine.switchProfile`), so there is
        // no window where the catalog and the active-profile pointer disagree.
        await coordinator.switchProfile(from: from, to: id)
        activeProfileID = id
        isSwitching = false
        // Re-baseline the freshly projected state against the cloud.
        coordinator.reconcile()
    }

    /// Delete a profile and all of its saved watch state. The last remaining
    /// profile can't be deleted. Deleting the active profile first switches to a
    /// surviving one so the catalog never keeps projecting the deleted profile.
    func deleteProfile(_ profile: UserProfile) async {
        let remaining = allProfiles().filter { $0.id != profile.id }
        guard let fallback = remaining.first else {
            Logger.sync.error("Refusing to delete the last remaining profile")
            return
        }
        if profile.id == activeProfileID {
            await switchProfile(to: fallback.id)
        }
        await coordinator.purgeProfileData(profile.id)
        LiveChannelHistory.purge(profileID: profile.id)
        context.delete(profile)
        try? context.save()
        refreshProfiles()
    }
}

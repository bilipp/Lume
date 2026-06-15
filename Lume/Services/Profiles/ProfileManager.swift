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

    private let container: ModelContainer
    private let coordinator: CloudSyncCoordinator

    init(container: ModelContainer, coordinator: CloudSyncCoordinator) {
        self.container = container
        self.coordinator = coordinator
        activeProfileID = ActiveProfileStore.current ?? UserProfile.defaultProfileID
        // `didSet` doesn't fire for the in-init assignment above, so seed the
        // cache directly (same single-row fetch shape) — keeps a profile resolved
        // on a prior launch available before `bootstrap()` runs.
        let resolvedID = activeProfileID
        var descriptor = FetchDescriptor<UserProfile>(predicate: #Predicate { $0.id == resolvedID })
        descriptor.fetchLimit = 1
        activeProfile = (try? container.mainContext.fetch(descriptor))?.first
    }

    private var context: ModelContext {
        container.mainContext
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
    }

    // MARK: - Queries

    func allProfiles() -> [UserProfile] {
        let descriptor = FetchDescriptor<UserProfile>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
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
        // not yet autosaved by the main context) so the engine — which reads the
        // catalog through its own background context — exports the outgoing
        // profile's *current* state rather than a stale snapshot.
        try? context.save()
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
    }
}

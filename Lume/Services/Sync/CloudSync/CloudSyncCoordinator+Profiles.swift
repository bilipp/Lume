import Foundation
import OSLog
import SwiftData

/// Profile bootstrap, switch and deletion, run through the active engine.
extension CloudSyncCoordinator {
    /// Bootstrap the profile store (ensure a default, resolve the active profile,
    /// claim legacy records). Falls back to the preferred/default id on failure
    /// so the app still launches into a usable profile.
    func bootstrapProfiles(preferredActiveID: UUID?, defaultName: String) async -> ProfileBootstrap {
        do {
            return try await engine.bootstrapProfiles(preferredActiveID: preferredActiveID, defaultName: defaultName)
        } catch {
            Logger.sync.error("Profile bootstrap failed: \(error.localizedDescription)")
            return ProfileBootstrap(
                activeProfileID: preferredActiveID ?? UserProfile.defaultProfileID,
                profileCount: 1
            )
        }
    }

    /// Re-project the catalog from one profile to another (flush, reset, hydrate).
    func switchProfile(from: UUID, to toID: UUID) async {
        do {
            try await engine.switchProfile(from: from, to: toID)
        } catch {
            Logger.sync.error("Profile switch failed: \(error.localizedDescription)")
        }
    }

    /// The user deleted a profile: purge its content state and sports follows,
    /// delete its row on the mirror's main context (the one the profile UI
    /// reads), refresh the mirror's readers, then, under Lume Cloud, queue
    /// tombstones for all of it; iCloud exports the deleted rows on its own.
    func deleteProfile(id: UUID) async {
        do {
            try await engine.purgeProfileData(id)
        } catch {
            Logger.sync.error("Profile purge failed: \(error.localizedDescription)")
        }
        let context = mirrorContainer.mainContext
        do {
            for profile in try context.fetch(FetchDescriptor<UserProfile>(predicate: #Predicate { $0.id == id })) {
                context.delete(profile)
            }
            try context.save()
        } catch {
            Logger.sync.error("Profile deletion failed: \(error.localizedDescription)")
        }
        notifyMirrorConsumers()
        await backend.recordProfileDeletion(id: id)
    }
}

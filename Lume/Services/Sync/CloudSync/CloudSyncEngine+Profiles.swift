import Foundation
import SwiftData

/// Outcome of `bootstrapProfiles`, handed back to `ProfileManager` so the UI
/// knows which profile is active and how many exist.
nonisolated struct ProfileBootstrap: Equatable {
    var activeProfileID: UUID
    var profileCount: Int
}

/// The profile-aware store operations: launch bootstrap, the active-profile
/// projection swap on switch, and per-profile data purge. Split out of
/// CloudSyncEngine.swift to keep that file within the project's size limit.
extension CloudSyncEngine {
    /// Ensure the profile store is in a usable state at launch: at least one
    /// profile exists, duplicate default profiles (a fixed id two devices can
    /// both create) are collapsed, the active profile is resolved, and any
    /// legacy `nil`-profileID content records are claimed by it. Idempotent.
    func bootstrapProfiles(preferredActiveID: UUID?, defaultName: String) throws -> ProfileBootstrap {
        var profiles = try dedupeProfiles(context.fetch(
            FetchDescriptor<UserProfile>(sortBy: [SortDescriptor(\.createdAt)])
        ))

        let defaultProfile: UserProfile
        if profiles.isEmpty {
            let created = UserProfile(id: UserProfile.defaultProfileID, name: defaultName)
            context.insert(created)
            profiles = [created]
            defaultProfile = created
        } else {
            defaultProfile = profiles.first { $0.id == UserProfile.defaultProfileID } ?? profiles[0]
        }

        let resolvedActive: UUID = if let preferredActiveID,
                                      profiles.contains(where: { $0.id == preferredActiveID })
        {
            preferredActiveID
        } else {
            defaultProfile.id
        }

        // An upgrading user's existing catalog is, by definition, the resolved
        // active profile's state — claim every unowned record for it.
        for record in try context.fetch(FetchDescriptor<UserContentState>())
            where record.profileID == nil
        {
            record.profileID = resolvedActive
        }

        if context.hasChanges { try context.save() }
        return ProfileBootstrap(activeProfileID: resolvedActive, profileCount: profiles.count)
    }

    /// Switch the catalog projection from one profile to another: flush the
    /// current catalog state into `from`'s mirrors, reset the catalog, then
    /// hydrate it from `to`'s mirrors. The content shadow is dropped so the next
    /// reconcile (which re-reads the active profile from `ActiveProfileStore`)
    /// re-baselines against the newly projected state.
    func switchProfile(from: UUID, to toID: UUID) throws {
        try exportCatalogState(toProfile: from)
        try resetCatalogUserState()
        try importProfileState(toID)
        shadow.resetContent()
        if context.hasChanges { try context.save() }
        shadow.persist()
    }

    /// Collapse duplicate profiles that CloudKit surfaced from another device.
    /// The default profile uses a fixed id, so two devices that each bootstrap
    /// before syncing both create one; once they sync, the store holds two rows
    /// sharing that id (CloudKit keys records by its own identifier, not our
    /// `id`, so it never merges them). Run on every reconcile — mirroring the
    /// defensive de-dup already applied to `SyncedPlaylist`/`UserContentState` —
    /// so a duplicate collapses as soon as the original imports, instead of
    /// lingering until the next launch. `dedupeProfiles` keeps the
    /// earliest-created, so every device converges on the same survivor.
    func reconcileProfiles() throws {
        _ = try dedupeProfiles(context.fetch(
            FetchDescriptor<UserProfile>(sortBy: [SortDescriptor(\.createdAt)])
        ))
    }

    /// Delete every content record owned by a profile (called when the profile
    /// itself is deleted). The `UserProfile` row is removed by `ProfileManager`.
    func purgeProfileData(_ profileID: UUID) throws {
        for mirror in try context.fetch(FetchDescriptor<UserContentState>())
            where (mirror.profileID ?? UserProfile.defaultProfileID) == profileID
        {
            context.delete(mirror)
        }
        if context.hasChanges { try context.save() }
    }
}

private extension CloudSyncEngine {
    /// Collapse duplicate `UserProfile` records sharing an id (only the fixed
    /// default id can collide, when two devices bootstrap before syncing),
    /// keeping the earliest-created and deleting the rest.
    func dedupeProfiles(_ profiles: [UserProfile]) -> [UserProfile] {
        var kept: [UUID: UserProfile] = [:]
        for profile in profiles {
            if let existing = kept[profile.id] {
                if profile.createdAt < existing.createdAt {
                    context.delete(existing)
                    kept[profile.id] = profile
                } else {
                    context.delete(profile)
                }
            } else {
                kept[profile.id] = profile
            }
        }
        return Array(kept.values).sorted { $0.createdAt < $1.createdAt }
    }

    /// Precisely sync the catalog's user state into a profile's mirrors: upsert
    /// every non-default catalog item, and delete mirrors whose catalog item was
    /// cleared this session (so an un-favorite during the session sticks).
    func exportCatalogState(toProfile profileID: UUID) throws {
        let localValues = try fetchLocalContentValues()
        var mirrors = try fetchMirrors(forProfile: profileID)
        for (id, entry) in localValues {
            upsertMirror(&mirrors, id: id, profileID: profileID, kind: entry.kind, values: entry.values)
        }
        for (id, mirror) in mirrors where localValues[id] == nil {
            context.delete(mirror)
        }
    }

    func resetCatalogUserState() throws {
        for entry in try fetchLocalContentValues().values {
            resetLocalContent(entry)
        }
    }

    func importProfileState(_ profileID: UUID) throws {
        for (id, mirror) in try fetchMirrors(forProfile: profileID) {
            _ = try applyContentToLocal(Self.values(from: mirror), id: id, kind: mirror.kind, loaded: nil)
        }
    }

    func upsertMirror(
        _ map: inout [String: UserContentState],
        id: String,
        profileID: UUID,
        kind: SyncedContentKind,
        values: ContentStateValues
    ) {
        if let mirror = map[id] {
            mirror.profileID = profileID
            mirror.kindRaw = kind.rawValue
            mirror.watchProgress = values.watchProgress
            mirror.isWatched = values.isWatched
            mirror.lastWatchedDate = values.lastWatchedDate
            mirror.isFavorite = values.isFavorite
            mirror.addedToWatchlistDate = values.addedToWatchlistDate
            mirror.favoriteOrder = values.favoriteOrder
            mirror.updatedAt = Date()
        } else {
            let mirror = UserContentState(
                contentId: id,
                kind: kind,
                profileID: profileID,
                watchProgress: values.watchProgress,
                isWatched: values.isWatched,
                lastWatchedDate: values.lastWatchedDate,
                isFavorite: values.isFavorite,
                addedToWatchlistDate: values.addedToWatchlistDate,
                favoriteOrder: values.favoriteOrder
            )
            context.insert(mirror)
            map[id] = mirror
        }
    }
}

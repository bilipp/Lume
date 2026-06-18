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
        var profiles = try dedupeProfiles(cloudContext.fetch(
            FetchDescriptor<UserProfile>(sortBy: [SortDescriptor(\.createdAt)])
        ))

        let defaultProfile: UserProfile
        if profiles.isEmpty {
            let created = UserProfile(id: UserProfile.defaultProfileID, name: defaultName)
            cloudContext.insert(created)
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
        // active profile's state — claim every unowned record for it. Filter to
        // `nil`-profileID records in the predicate (served by the
        // `UserContentState.profileID` index) so launch seeks the legacy rows
        // instead of scanning every per-item mirror.
        let unownedDescriptor = FetchDescriptor<UserContentState>(
            predicate: #Predicate { $0.profileID == nil }
        )
        for record in try cloudContext.fetch(unownedDescriptor) {
            record.profileID = resolvedActive
        }

        try saveStores()
        return ProfileBootstrap(activeProfileID: resolvedActive, profileCount: profiles.count)
    }

    /// Switch the catalog projection from one profile to another: flush the
    /// current catalog state into `from`'s mirrors, reset the catalog, then
    /// hydrate it from `to`'s mirrors. The content shadow is dropped so the next
    /// reconcile (which re-reads the active profile from `ActiveProfileStore`)
    /// re-baselines against the newly projected state.
    func switchProfile(from: UUID, to toID: UUID) throws {
        // Gather the catalog's current user-state once and reuse it for both the
        // export into the outgoing profile's mirrors and the catalog reset — these
        // each used to re-run the four catalog fetches, tripling the work per
        // switch.
        let localValues = try fetchLocalContentValues()
        try exportCatalogState(toProfile: from, localValues: localValues)
        resetCatalogUserState(localValues: localValues)
        try importProfileState(toID)
        shadow.resetContent()
        try saveStores()
        shadow.persist()
        // Flip the active-profile pointer *inside* this actor-isolated critical
        // section, atomically with the projection swap and shadow reset — not
        // afterwards on the main actor. `reconcile()` reads the active profile
        // from `ActiveProfileStore` at the start of every pass, and reconciles
        // are fired constantly by CloudKit remote-change / scene-phase / content-
        // sync observers. If one is serialized on this actor between the swap and
        // a later store update, it would observe the freshly-projected catalog
        // while the pointer still names the old profile — merging the new
        // catalog into the old profile's mirrors (and the old profile's state
        // back onto the new catalog). Committing it here closes that window:
        // every reconcile now sees a catalog and an active-profile pointer that
        // agree, because both change in the same critical section.
        ActiveProfileStore.current = toID
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
        _ = try dedupeProfiles(cloudContext.fetch(
            FetchDescriptor<UserProfile>(sortBy: [SortDescriptor(\.createdAt)])
        ))
    }

    /// Delete every content record owned by a profile (called when the profile
    /// itself is deleted). The `UserProfile` row is removed by `ProfileManager`.
    func purgeProfileData(_ profileID: UUID) throws {
        // Scope the fetch with a predicate (served by the
        // `UserContentState.profileID` index) instead of scanning every mirror.
        // Records with a `nil` profileID are treated as belonging to the default
        // profile, so include them only when purging the default.
        let isDefault = profileID == UserProfile.defaultProfileID
        let descriptor = FetchDescriptor<UserContentState>(
            predicate: #Predicate {
                $0.profileID == profileID || (isDefault && $0.profileID == nil)
            }
        )
        for mirror in try cloudContext.fetch(descriptor) {
            cloudContext.delete(mirror)
        }
        try saveStores()
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
                    cloudContext.delete(existing)
                    kept[profile.id] = profile
                } else {
                    cloudContext.delete(profile)
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
    func exportCatalogState(toProfile profileID: UUID, localValues: [String: LocalContentEntry]) throws {
        var mirrors = try fetchMirrors(forProfile: profileID)
        for (id, entry) in localValues {
            upsertMirror(&mirrors, id: id, profileID: profileID, kind: entry.kind, values: entry.values)
        }
        for (id, mirror) in mirrors where localValues[id] == nil {
            cloudContext.delete(mirror)
        }
    }

    func resetCatalogUserState(localValues: [String: LocalContentEntry]) {
        for entry in localValues.values {
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
            mirror.recommendationVoteRaw = values.recommendationVoteRaw
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
                favoriteOrder: values.favoriteOrder,
                recommendationVoteRaw: values.recommendationVoteRaw
            )
            cloudContext.insert(mirror)
            map[id] = mirror
        }
    }
}

//
//  SportsFollowService.swift
//  Lume
//
//  The app-facing reader/writer for the per-profile sports follows that sync
//  through the CloudKit mirror (`SyncedSportsFollow` in `CloudUserData.store`).
//
//  Follows are read and written directly over the cloud store's main context —
//  never a `@Query` against the mirror (that container's CloudKit churn would
//  invalidate the browse `@Query`s; see the two-container split). This mirrors
//  `ProfileManager`, which owns `UserProfile` on the same store the same way.
//
//  It also satisfies `SportsFollowSource`, so `SportsSyncService` refreshes the
//  leagues this profile actually follows. That seam is `nonisolated`, so the
//  followed ids are published into a lock-guarded snapshot readable off the main
//  actor while the observable `follows` array drives the SwiftUI hub.
//

import Foundation
import Observation
import os
import SwiftData
import SwiftUI

// MARK: - Value type

/// What a follow points at: a whole league or a single team.
nonisolated enum SportsFollowKind: String, Codable, Hashable {
    case league
    case team
}

/// A single followed league or team, as the hub reads it. `key` is the
/// provider-prefixed identifier (`"espn:soccer/ger.1"` for a league,
/// `"espn:soccer/ger.1:132"` for a team) and also the value's identity.
nonisolated struct SportsFollow: Identifiable, Codable, Hashable {
    let key: String
    let kind: SportsFollowKind
    let sortOrder: Int

    var id: String {
        key
    }
}

// MARK: - Service

@MainActor
@Observable
final class SportsFollowService {
    static let shared = SportsFollowService()

    /// The active profile's follows, ordered — the first few lead the Home shelf.
    private(set) var follows: [SportsFollow] = []

    private var container: ModelContainer?
    private var profileManager: ProfileManager?
    private let defaults: UserDefaults

    /// The followed ids, mirrored into a lock so `SportsSyncService` can read them
    /// off the main actor through `SportsFollowSource`. Kept in step with `follows`.
    private nonisolated let snapshot = OSAllocatedUnfairLock(initialState: FollowSnapshot())

    private nonisolated struct FollowSnapshot {
        var leagues: [String] = []
        var teams: [String] = []
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Wire the cloud store (and, in the app, the `ProfileManager` whose active
    /// profile scopes the follows). Loads the current profile's follows and runs
    /// the one-time per-profile pre-follow bootstrap.
    func configure(container: ModelContainer, profileManager: ProfileManager? = nil) {
        self.container = container
        self.profileManager = profileManager
        reload()
        observeProfileSwitch()
    }

    private var context: ModelContext? {
        container?.mainContext
    }

    /// The profile whose follows are shown. Prefers the live `ProfileManager` (so
    /// a switch is reflected) and falls back to the persisted active id, mirroring
    /// `CloudSyncEngine`.
    private var currentProfileID: UUID {
        profileManager?.activeProfileID ?? ActiveProfileStore.current ?? UserProfile.defaultProfileID
    }

    // MARK: - Reads

    func isFollowing(_ key: String) -> Bool {
        follows.contains { $0.key == key }
    }

    /// Every followed key (leagues and teams), for membership checks such as
    /// highlighting a followed team's standings row.
    var followedKeys: Set<String> {
        Set(follows.map(\.key))
    }

    // MARK: - Mutations

    /// Follow a league or team, appended to the end of the profile's order. A
    /// no-op when it is already followed.
    func follow(_ key: String, kind: SportsFollowKind) {
        guard let context, !isFollowing(key) else { return }
        let nextOrder = (follows.map(\.sortOrder).max() ?? -1) + 1
        context.insert(SyncedSportsFollow(
            key: key,
            kindRaw: kind.rawValue,
            profileID: currentProfileID,
            sortOrder: nextOrder
        ))
        try? context.save()
        // `reload()` fetches the newly followed league — see its comment.
        reload()
    }

    /// Follow when not yet followed, unfollow when it already is.
    func toggle(_ key: String, kind: SportsFollowKind) {
        if isFollowing(key) {
            unfollow(key)
        } else {
            follow(key, kind: kind)
        }
    }

    /// Unfollow, removing every mirror row for this key under the active profile.
    func unfollow(_ key: String) {
        guard let context else { return }
        for row in fetchRows() where row.key == key {
            context.delete(row)
        }
        try? context.save()
        reload()
    }

    /// Reorder the follow list (from an `onMove`), rewriting every row's
    /// `sortOrder` to its new position.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let context else { return }
        var reordered = follows
        reordered.move(fromOffsets: source, toOffset: destination)
        let rowsByKey = Dictionary(fetchRows().map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        for (index, follow) in reordered.enumerated() {
            guard let row = rowsByKey[follow.key], row.sortOrder != index else { continue }
            row.sortOrder = index
            row.updatedAt = now
        }
        try? context.save()
        reload()
    }

    /// Persist an explicit follow arrangement in a single batched pass. The tvOS
    /// pick-up/place reorder commits the whole order at once (rather than the
    /// `IndexSet`/offset move the iOS list uses), so it hands back the finished
    /// array here.
    func setOrder(_ ordered: [SportsFollow]) {
        guard let context else { return }
        let rowsByKey = Dictionary(fetchRows().map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        for (index, follow) in ordered.enumerated() {
            guard let row = rowsByKey[follow.key], row.sortOrder != index else { continue }
            row.sortOrder = index
            row.updatedAt = now
        }
        try? context.save()
        reload()
    }

    // MARK: - Reload

    /// Re-read the active profile's follows from the cloud store and republish the
    /// observable array and the off-main snapshot. Called on configure, on profile
    /// switch, and after each reconcile.
    func reload() {
        guard container != nil else { return }
        bootstrapPreFollowsIfNeeded()
        let loaded = fetchRows().map {
            SportsFollow(
                key: $0.key,
                kind: SportsFollowKind(rawValue: $0.kindRaw) ?? .team,
                sortOrder: $0.sortOrder
            )
        }
        let gained = Set(loaded.map(\.key)).subtracting(follows.map(\.key))
        follows = loaded
        publishSnapshot(loaded)
        // Follows that arrived from elsewhere — an iCloud reconcile landing
        // another device's teams, a profile switch, the first-run pre-follows —
        // need their leagues fetched now. The Home rail hides itself while it
        // has no fixtures, so it can never ask for them on its own.
        if !gained.isEmpty {
            SportsSyncService.shared.refreshMissing()
        }
    }

    private func fetchRows() -> [SyncedSportsFollow] {
        guard let context else { return [] }
        let profileID = currentProfileID
        let isDefault = profileID == UserProfile.defaultProfileID
        let descriptor = FetchDescriptor<SyncedSportsFollow>(
            predicate: #Predicate { $0.profileID == profileID || (isDefault && $0.profileID == nil) },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func publishSnapshot(_ follows: [SportsFollow]) {
        let leagues = follows.filter { $0.kind == .league }.map(\.key)
        let teams = follows.filter { $0.kind == .team }.map(\.key)
        snapshot.withLock { $0 = FollowSnapshot(leagues: leagues, teams: teams) }
    }

    // MARK: - Pre-follow bootstrap

    /// Seed a fresh profile's follows from its device region, exactly once per
    /// profile. The stamp is set on the first attempt whether or not rows are
    /// written, so a user who later removes every pre-follow is not re-seeded.
    private func bootstrapPreFollowsIfNeeded() {
        guard let context else { return }
        let profileID = currentProfileID
        let stampKey = Self.preFollowStampKey(for: profileID)
        guard !defaults.bool(forKey: stampKey) else { return }
        defaults.set(true, forKey: stampKey)

        let existing = fetchRows()
        guard existing.isEmpty else { return }

        let leagueIds = SportsCatalog.regionPreFollows(for: Locale.current.region)
        let now = Date()
        for (index, leagueId) in leagueIds.enumerated() {
            context.insert(SyncedSportsFollow(
                key: leagueId,
                kindRaw: SportsFollowKind.league.rawValue,
                profileID: profileID,
                sortOrder: index,
                updatedAt: now
            ))
        }
        try? context.save()
    }

    nonisolated static func preFollowStampKey(for profileID: UUID) -> String {
        "sports.prefollow.\(profileID.uuidString)"
    }

    // MARK: - Profile-switch observation

    /// Re-read follows whenever the active profile changes. `withObservationTracking`
    /// fires once, so the change handler re-arms it.
    private func observeProfileSwitch() {
        guard let profileManager else { return }
        withObservationTracking {
            _ = profileManager.activeProfileID
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reload()
                self?.observeProfileSwitch()
            }
        }
    }
}

// MARK: - SportsFollowSource

extension SportsFollowService: SportsFollowSource {
    nonisolated var followedLeagueIds: [String] {
        snapshot.withLock { $0.leagues }
    }

    nonisolated var followedTeamIds: [String] {
        snapshot.withLock { $0.teams }
    }
}

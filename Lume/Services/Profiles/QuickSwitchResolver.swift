//
//  QuickSwitchResolver.swift
//  Lume
//
//  The single answer to "which playlist / which profile is currently active, and
//  which rows can be switched to" — shared by every switch surface (the iOS /
//  macOS toolbar switcher, the tvOS Settings panes, the tvOS quick-switch
//  overlay) so the decision never gets a fourth divergent copy.
//
//  Deliberately platform-agnostic and view-free: the test targets exclude
//  appletvos, so nothing here may be gated behind `#if os(tvOS)`.
//

import Foundation

// MARK: - Rows

/// One row on a switch surface: the playlist or profile it stands for, plus
/// whether it is the one in effect right now — including via the
/// empty-selection / deleted-playlist fallback to the first playlist.
struct QuickSwitchRow<Item>: Identifiable {
    let item: Item
    let isCurrent: Bool
    /// Out of reach on the free plan — see `[Playlist].isLocked(_:isPremium:)`.
    /// A locked row stays listed and opens the paywall instead of switching.
    var isLocked = false
    let id: UUID
}

// MARK: - Active playlist

extension [Playlist] {
    /// Resolves the stored selection (the raw `PlaylistSelectionStore.key` value)
    /// to a concrete playlist, falling back to the oldest playlist when the
    /// stored id is empty or no longer exists (e.g. the selected playlist was
    /// deleted), or names a playlist the free plan has locked.
    ///
    /// The fallback is ordered rather than `first`: callers resolve against
    /// their own unsorted `@Query` or fetch, whose order SQLite doesn't promise
    /// to repeat, and the content tabs, the switchers and auto-sync all have to
    /// land on the same playlist.
    ///
    /// The stored selection itself is left alone, so renewing Pro lands the
    /// viewer back on the playlist they had picked.
    func active(for storedID: String, isPremium: Bool? = nil) -> Playlist? {
        active(for: storedID, isPremium: PremiumManager.isPremium(isPremium))
    }

    nonisolated func active(for storedID: String, isPremium: Bool) -> Playlist? {
        unlocked(isPremium: isPremium).first { $0.id.uuidString == storedID } ?? oldest
    }

    /// The playlist added first — the free plan's one playlist, and the
    /// fallback whenever the stored selection can't be used.
    nonisolated var oldest: Playlist? {
        self.min { ($0.addedAt, $0.id.uuidString) < ($1.addedAt, $1.id.uuidString) }
    }

    /// Whether the plan puts `playlist` out of reach. The free plan includes one
    /// playlist, the oldest; the rest still arrive — iCloud and Lume Cloud bring
    /// over every playlist added on a device with Pro, or in Lume for Android —
    /// and stay listed in Settings so they can be deleted or unlocked, but are
    /// never selected, synced, searched or played.
    ///
    /// `isPremium` pins the plan (tests); nil reads `PremiumManager`. The same
    /// goes for every plan-aware helper here; the overloads taking a plain
    /// `Bool` are the ones callable off the main actor.
    func isLocked(_ playlist: Playlist, isPremium: Bool? = nil) -> Bool {
        !PremiumManager.isPremium(isPremium) && playlist.id != oldest?.id
    }

    /// Whether a catalog row came from a playlist the plan locks, by the
    /// playlist prefix on its id. An id no playlist owns isn't locked.
    func isLocked(contentID: String, isPremium: Bool? = nil) -> Bool {
        owner(ofContentID: contentID).map { isLocked($0, isPremium: isPremium) } ?? false
    }

    /// The playlists the plan can use: all of them with Pro, else the oldest.
    func unlocked(isPremium: Bool? = nil) -> [Playlist] {
        unlocked(isPremium: PremiumManager.isPremium(isPremium))
    }

    nonisolated func unlocked(isPremium: Bool) -> [Playlist] {
        isPremium ? self : (oldest.map { [$0] } ?? [])
    }

    /// The playlist that synced a piece of content. Every catalog id is
    /// prefixed with its playlist's UUID (see `ContentSyncManager`), and that
    /// prefix is the only thing tying a row back to the server and credentials
    /// that can actually play it. Callers that surface content from more than
    /// one playlist — search with "Search All Playlists" on — must resolve the
    /// owner this way rather than reaching for the active playlist. Returns
    /// `nil` for an id no current playlist owns, so callers pick their own
    /// fallback.
    nonisolated func owner(ofContentID contentID: String) -> Playlist? {
        first { contentID.hasPrefix($0.id.uuidString) }
    }

    /// The in-effect playlist's `id.uuidString`, or an empty string when there is
    /// no playlist at all. Never compare a raw stored value instead — it can name
    /// a deleted playlist.
    func activeID(for storedID: String, isPremium: Bool? = nil) -> String {
        activeID(for: storedID, isPremium: PremiumManager.isPremium(isPremium))
    }

    nonisolated func activeID(for storedID: String, isPremium: Bool) -> String {
        active(for: storedID, isPremium: isPremium)?.id.uuidString ?? ""
    }
}

// MARK: - Plan

extension PremiumManager {
    /// `override` when given, else the live plan. The plan-aware playlist
    /// helpers take an optional rather than defaulting to `shared.isPremium`:
    /// a default argument is evaluated outside the main actor.
    static func isPremium(_ override: Bool?) -> Bool {
        override ?? shared.isPremium
    }
}

// MARK: - Resolver

enum QuickSwitchResolver {
    // MARK: Playlists

    /// The playlist rows in the order they were handed in, each tagged with
    /// whether it is current and whether the plan locks it.
    static func playlistRows(
        _ playlists: [Playlist],
        storedID: String,
        isPremium: Bool? = nil
    ) -> [QuickSwitchRow<Playlist>] {
        let isPremium = PremiumManager.isPremium(isPremium)
        let currentID = playlists.active(for: storedID, isPremium: isPremium)?.id
        return playlists.map { playlist in
            QuickSwitchRow(
                item: playlist,
                isCurrent: playlist.id == currentID,
                isLocked: playlists.isLocked(playlist, isPremium: isPremium),
                id: playlist.id
            )
        }
    }

    // MARK: Profiles

    /// The active profile out of `profiles` (always `ProfileManager.profiles` —
    /// `UserProfile` lives in the CloudKit-mirrored container, which the view
    /// contexts don't bind to, so it can never come from a `@Query`).
    static func currentProfile(in profiles: [UserProfile], activeProfileID: UUID) -> UserProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    /// The profile rows in roster order, each tagged with whether it is active.
    static func profileRows(_ profiles: [UserProfile], activeProfileID: UUID) -> [QuickSwitchRow<UserProfile>] {
        rows(profiles, id: \.id, currentID: activeProfileID)
    }

    // MARK: Shared

    private static func rows<Item>(
        _ items: [Item],
        id: (Item) -> UUID,
        currentID: UUID?
    ) -> [QuickSwitchRow<Item>] {
        items.map { item in
            let itemID = id(item)
            return QuickSwitchRow(item: item, isCurrent: itemID == currentID, id: itemID)
        }
    }
}

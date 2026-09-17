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
    let id: UUID
}

// MARK: - Active playlist

extension [Playlist] {
    /// Resolves the stored selection (the raw `PlaylistSelectionStore.key` value)
    /// to a concrete playlist, falling back to the first available playlist when
    /// the stored id is empty or no longer exists (e.g. the selected playlist was
    /// deleted).
    func active(for storedID: String) -> Playlist? {
        first(where: { $0.id.uuidString == storedID }) ?? first
    }

    /// The playlist that synced a piece of content. Every catalog id is
    /// prefixed with its playlist's UUID (see `ContentSyncManager`), and that
    /// prefix is the only thing tying a row back to the server and credentials
    /// that can actually play it. Callers that surface content from more than
    /// one playlist — search with "Search All Playlists" on — must resolve the
    /// owner this way rather than reaching for the active playlist. Returns
    /// `nil` for an id no current playlist owns, so callers pick their own
    /// fallback.
    func owner(ofContentID contentID: String) -> Playlist? {
        first { contentID.hasPrefix($0.id.uuidString) }
    }

    /// The in-effect playlist's `id.uuidString`, or an empty string when there is
    /// no playlist at all. Never compare a raw stored value instead — it can name
    /// a deleted playlist.
    func activeID(for storedID: String) -> String {
        active(for: storedID)?.id.uuidString ?? ""
    }
}

// MARK: - Resolver

enum QuickSwitchResolver {
    // MARK: Playlists

    /// The playlist rows in the order they were handed in, each tagged with
    /// whether it is current.
    static func playlistRows(_ playlists: [Playlist], storedID: String) -> [QuickSwitchRow<Playlist>] {
        rows(playlists, id: \.id, currentID: playlists.active(for: storedID)?.id)
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

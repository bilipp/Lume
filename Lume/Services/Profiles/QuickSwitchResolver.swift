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
    /// Whether the item is in effect for its sync state: every Combined member
    /// is, while no playlist row is current. A profile row is when current.
    let isInScope: Bool
    let id: UUID
}

/// What picking the Combined entry on a switch surface does.
enum CombinedSwitchAction: Equatable {
    /// Combined is a Lume Pro feature: the paywall opens instead.
    case paywall
    /// Fewer than two playlists are in it: Settings › Combined View opens.
    case configure
    case alreadyCurrent
    case switchToCombined
}

/// The playlist column of a switch surface: the Combined entry plus one row
/// per playlist. When Combined is current no playlist row is.
struct QuickSwitchPlaylistColumn {
    let rows: [QuickSwitchRow<Playlist>]
    let isCombinedCurrent: Bool
    let combinedAction: CombinedSwitchAction
    /// The members in priority order — even when Combined can't be entered,
    /// so a lapsed config still reads as configured.
    let combinedMemberNames: [String]
}

// MARK: - Active playlist

extension [Playlist] {
    /// Resolves the stored selection (the raw `PlaylistSelectionStore.key` value)
    /// to a concrete playlist, falling back to the oldest playlist when the
    /// stored id is empty or no longer exists (e.g. the selected playlist was
    /// deleted).
    ///
    /// The fallback is ordered rather than `first`: callers resolve against
    /// their own unsorted `@Query` or fetch, whose order SQLite doesn't promise
    /// to repeat, and the content tabs, the switchers and auto-sync all have to
    /// land on the same playlist.
    func active(for storedID: String) -> Playlist? {
        first(where: { $0.id.uuidString == storedID })
            ?? self.min { ($0.addedAt, $0.id.uuidString) < ($1.addedAt, $1.id.uuidString) }
    }

    /// The playlist that synced a piece of content. Every catalog id is
    /// prefixed with its playlist's UUID (see `ContentSyncManager`), and that
    /// prefix is the only thing tying a row back to the server and credentials
    /// that can actually play it. Callers that surface content from more than
    /// one playlist — search with "Search All Playlists" on — must resolve the
    /// owner this way rather than reaching for the active playlist. Returns
    /// `nil` for an id no current playlist owns — never another playlist in
    /// its place, which would play the item from the wrong provider.
    nonisolated func owner(ofContentID contentID: String) -> Playlist? {
        first { contentID.hasPrefix($0.id.uuidString) }
    }
}

// MARK: - Catalog scope

extension [Playlist] {
    /// The playlists in the Combined selection, in priority order: by
    /// `combinedPriority` (unset last), then `addedAt`, then id, so every
    /// surface agrees on the order whatever order the fetch returned. A
    /// playlist whose source type this build doesn't know is skipped.
    var combinedMembers: [Playlist] {
        filter { $0.isCombinedMember && $0.knownSourceType != nil }
            .sorted {
                ($0.combinedPriority ?? .max, $0.addedAt, $0.id.uuidString)
                    < ($1.combinedPriority ?? .max, $1.addedAt, $1.id.uuidString)
            }
    }

    /// Resolves the stored selection (the raw `PlaylistSelectionStore.key`
    /// value) to the scope every browse surface reads from.
    ///
    /// `PlaylistSelectionStore.combined` resolves to the members only for a Pro
    /// user with at least two of them. Otherwise it falls back to the
    /// priority-1 member — or, with none, the oldest playlist — on every read.
    /// The fallback is never written back: a lapsed subscription or a
    /// temporarily removed member must not discard the selection or the config.
    func scope(for selection: String?, isPremium: Bool) -> CatalogScope {
        let stored = selection ?? ""
        guard stored == PlaylistSelectionStore.combined else {
            return active(for: stored).map { .isolated($0.id) } ?? .empty
        }
        let members = combinedMembers
        if isPremium, members.count >= 2 {
            return .combined(members.map { (id: $0.id, tabs: $0.combinedTabs) })
        }
        if let first = members.first {
            return .isolated(first.id)
        }
        return active(for: "").map { .isolated($0.id) } ?? .empty
    }

    /// The scope's priority-1 member — the isolated playlist outside Combined.
    /// Only for the few reads that need exactly one playlist; everything that
    /// lists content reads the whole scope.
    func primaryMember(of scope: CatalogScope) -> Playlist? {
        guard let id = scope.primaryID else { return nil }
        return first { $0.id == id }
    }

    /// The scope's members, in priority order.
    func members(of scope: CatalogScope) -> [Playlist] {
        scope.playlistIDs.compactMap { id in first { $0.id == id } }
    }

    /// The Combined members in priority order; empty outside Combined.
    func combinedMembers(of scope: CatalogScope) -> [Playlist] {
        scope.isCombined ? members(of: scope) : []
    }

    /// The member a settings screen picked, while it is still in the Combined
    /// scope; nil outside Combined or once it has left.
    func pickedMember(_ id: UUID?, in scope: CatalogScope) -> Playlist? {
        guard scope.isCombined, let id, scope.playlistIDs.contains(id) else { return nil }
        return first { $0.id == id }
    }

    /// The members contributing `tab`, in priority order.
    func members(of scope: CatalogScope, for tab: PlaylistTab) -> [Playlist] {
        scope.members(for: tab).compactMap { id in first { $0.id == id } }
    }

    var namesByID: [UUID: String] {
        Dictionary(map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - Resolver

enum QuickSwitchResolver {
    // MARK: Playlists

    /// The playlist rows for a resolved scope. In Combined no single playlist
    /// is current; a Combined selection that fell back marks the playlist it
    /// fell back to.
    static func playlistRows(_ playlists: [Playlist], scope: CatalogScope) -> [QuickSwitchRow<Playlist>] {
        let inScope = Set(scope.playlistIDs)
        return rows(playlists, id: \.id, currentID: scope.isCombined ? nil : scope.primaryID, isInScope: inScope.contains)
    }

    /// A switch surface's playlist column: the Combined entry above the
    /// playlist rows, and which of them is current.
    static func playlistColumn(
        _ playlists: [Playlist],
        scope: CatalogScope,
        isPremium: Bool
    ) -> QuickSwitchPlaylistColumn {
        QuickSwitchPlaylistColumn(
            rows: playlistRows(playlists, scope: scope),
            isCombinedCurrent: scope.isCombined,
            combinedAction: combinedAction(playlists, scope: scope, isPremium: isPremium),
            combinedMemberNames: playlists.combinedMembers.map(\.name)
        )
    }

    /// What picking Combined does. It is offered to everyone; only a Pro user
    /// with two or more members actually switches to it.
    static func combinedAction(_ playlists: [Playlist], scope: CatalogScope, isPremium: Bool) -> CombinedSwitchAction {
        guard isPremium else { return .paywall }
        guard playlists.combinedMembers.count >= 2 else { return .configure }
        return scope.isCombined ? .alreadyCurrent : .switchToCombined
    }

    /// What Settings' Combined View row does: `.paywall` for a Free user with
    /// nothing configured, where the page would only repeat it, otherwise
    /// `.configure`. A lapsed subscriber's config stays reachable and editable;
    /// only choosing Combined is gated.
    static func combinedSettingsAction(_ playlists: [Playlist], isPremium: Bool) -> CombinedSwitchAction {
        !isPremium && !playlists.contains(where: \.isCombinedMember) ? .paywall : .configure
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
        rows(profiles, id: \.id, currentID: activeProfileID) { $0 == activeProfileID }
    }

    // MARK: Shared

    private static func rows<Item>(
        _ items: [Item],
        id: (Item) -> UUID,
        currentID: UUID?,
        isInScope: (UUID) -> Bool
    ) -> [QuickSwitchRow<Item>] {
        items.map { item in
            let itemID = id(item)
            return QuickSwitchRow(item: item, isCurrent: itemID == currentID, isInScope: isInScope(itemID), id: itemID)
        }
    }
}

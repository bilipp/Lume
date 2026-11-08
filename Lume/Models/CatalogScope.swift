//
//  CatalogScope.swift
//  Lume
//
//  The set of playlists a browse surface reads from: one playlist in isolated
//  mode, the ordered members of the Combined selection otherwise. Resolved by
//  `[Playlist].scope(for:isPremium:)`; never persisted.
//

import Foundation
import SwiftData
import SwiftUI

nonisolated struct CatalogScope: Hashable {
    /// Members in priority order. A single element is isolated mode.
    let playlistIDs: [UUID]
    /// The content types each member contributes. Isolated members contribute
    /// every type.
    let contributions: [UUID: Set<PlaylistTab>]
    let isCombined: Bool

    private init(playlistIDs: [UUID], contributions: [UUID: Set<PlaylistTab>], isCombined: Bool) {
        self.playlistIDs = playlistIDs
        self.contributions = contributions
        self.isCombined = isCombined
    }

    /// No playlist at all: every predicate matches nothing.
    static let empty = CatalogScope(playlistIDs: [], contributions: [:], isCombined: false)

    static func isolated(_ playlistID: UUID) -> CatalogScope {
        CatalogScope(
            playlistIDs: [playlistID],
            contributions: [playlistID: Set(PlaylistTab.allCases)],
            isCombined: false
        )
    }

    /// `members` in priority order. Callers resolve the fallback for fewer than
    /// two members before getting here.
    static func combined(_ members: [(id: UUID, tabs: Set<PlaylistTab>)]) -> CatalogScope {
        CatalogScope(
            playlistIDs: members.map(\.id),
            contributions: Dictionary(members.map { ($0.id, $0.tabs) }, uniquingKeysWith: { first, _ in first }),
            isCombined: true
        )
    }
}

nonisolated extension CatalogScope {
    var isEmpty: Bool {
        playlistIDs.isEmpty
    }

    /// The priority-1 member, or the isolated playlist.
    var primaryID: UUID? {
        playlistIDs.first
    }

    /// Every member's catalog id prefix (`"<uuid>-"`), in priority order.
    var prefixes: [String] {
        playlistIDs.map(Self.prefix)
    }

    /// A stable key for memos, caches and `.task(id:)`. An isolated scope's
    /// token is the playlist's `uuidString`, the value those keys used before
    /// scopes existed.
    var token: String {
        if isEmpty { return "none" }
        guard isCombined else { return playlistIDs[0].uuidString }
        let members = playlistIDs.map { id in
            "\(id.uuidString):\(PlaylistTab.encode(contributions[id] ?? []))"
        }
        return "combined|" + members.joined(separator: "|")
    }

    func contributes(_ tab: PlaylistTab, from playlistID: UUID) -> Bool {
        contributions[playlistID]?.contains(tab) == true
    }

    /// The members contributing `tab`, in priority order.
    func members(for tab: PlaylistTab) -> [UUID] {
        playlistIDs.filter { contributions[$0]?.contains(tab) == true }
    }

    func prefixes(for tab: PlaylistTab) -> [String] {
        members(for: tab).map(Self.prefix)
    }

    /// The prefix when exactly one member contributes `tab`. A query that adds
    /// its own conditions inlines this as `id.starts(with:)` rather than going
    /// through `evaluate`, so isolated mode keeps the predicate it always had.
    func singlePrefix(for tab: PlaylistTab) -> String? {
        let prefixes = prefixes(for: tab)
        return prefixes.count == 1 ? prefixes[0] : nil
    }

    /// A member's catalog id prefix (`"<uuid>-"`).
    static func prefix(_ id: UUID) -> String {
        "\(id.uuidString)-"
    }

    /// Whether rows of `tab` name their member: only while two or more members
    /// contribute it, so a single playlist reads as it did before Combined.
    func namesMembers(for tab: PlaylistTab) -> Bool {
        members(for: tab).count > 1
    }

    /// `items` split by the member of `tab` whose prefix each id carries, in
    /// priority order. Keeps the order within each member; members with nothing
    /// and items no member owns are left out.
    func groupedByMember<T>(_ items: [T], for tab: PlaylistTab, id: (T) -> String) -> [(member: UUID, items: [T])] {
        Self.grouped(items, byMember: members(for: tab), id: id)
    }

    /// `groupedByMember(_:for:id:)` over an explicit member order.
    static func grouped<T>(_ items: [T], byMember members: [UUID], id: (T) -> String) -> [(member: UUID, items: [T])] {
        guard let first = members.first else { return [] }
        let prefixLength = prefix(first).count
        let byPrefix = Dictionary(grouping: items) { id($0).prefix(prefixLength) }
        return members.compactMap { member in
            byPrefix[Substring(prefix(member))].map { (member: member, items: $0) }
        }
    }
}

// MARK: - Live surfing

/// The Combined members in-player Favorites and Recently Watched surfing walk,
/// in priority order. The `Codable` form of a scope's Live TV members, carried
/// on `PlayableMedia` so the scope rides with the playing channel into resume
/// snapshots and macOS window restoration, which have no selection to resolve
/// it from. Category surfing never reads it: categories belong to one playlist.
nonisolated struct LiveSurfScope: Hashable, Codable {
    let playlistIDs: [UUID]

    /// The scope to walk for a channel owned by `owner`: every member, or that
    /// playlist alone when it is no longer one of them.
    func catalogScope(owner: UUID) -> CatalogScope {
        guard playlistIDs.count > 1, playlistIDs.contains(owner) else { return .isolated(owner) }
        return .combined(playlistIDs.map { (id: $0, tabs: [PlaylistTab.liveTV]) })
    }
}

nonisolated extension LiveSurfScope {
    /// `nil` unless at least two members contribute Live TV, so isolated
    /// playback carries nothing and keeps the single-playlist rings.
    init?(_ scope: CatalogScope) {
        let members = scope.members(for: .liveTV)
        guard scope.isCombined, members.count > 1 else { return nil }
        self.init(playlistIDs: members)
    }
}

// MARK: - Predicates

/// One member renders exactly the isolated-mode predicate, `id.starts(with:)`,
/// a range seek on the unique `id` index. Several members fold into an OR of
/// those with `Predicate.evaluate`, which SQLite plans as a MULTI-INDEX OR.
/// Never fetch per member and merge in Swift: that doubled the cost and breaks
/// positional reads.
nonisolated extension CatalogScope {
    func moviePredicate() -> Predicate<Movie> {
        Self.fold(prefixes(for: .movies)) { prefix in #Predicate<Movie> { $0.id.starts(with: prefix) } }
    }

    func seriesPredicate() -> Predicate<Series> {
        Self.fold(prefixes(for: .series)) { prefix in #Predicate<Series> { $0.id.starts(with: prefix) } }
    }

    func liveStreamPredicate() -> Predicate<LiveStream> {
        Self.fold(prefixes(for: .liveTV)) { prefix in #Predicate<LiveStream> { $0.id.starts(with: prefix) } }
    }

    func categoryPredicate(for tab: PlaylistTab) -> Predicate<Category> {
        Self.fold(prefixes(for: tab)) { prefix in #Predicate<Category> { $0.id.starts(with: prefix) } }
    }

    private static func fold<Model: PersistentModel>(
        _ prefixes: [String],
        single: (String) -> Predicate<Model>
    ) -> Predicate<Model> {
        guard let first = prefixes.first else { return #Predicate<Model> { _ in false } }
        return prefixes.dropFirst().reduce(single(first)) { accumulated, prefix in
            let next = single(prefix)
            return #Predicate<Model> { accumulated.evaluate($0) || next.evaluate($0) }
        }
    }
}

extension EnvironmentValues {
    /// The scope `MainTabView` resolved for the content tabs, so every tab reads
    /// the same one.
    @Entry var catalogScope = CatalogScope.empty
}

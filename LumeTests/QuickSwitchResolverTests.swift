//
//  QuickSwitchResolverTests.swift
//  LumeTests
//
//  Covers the shared quick-switch seam every switch surface reads its "which
//  row is current" answer from: the stored-selection fallbacks of
//  `[Playlist].active(for:)`, row ordering, and the `isCurrent` tag. Also
//  `owner(ofContentID:)`, which answers the other question — not which
//  playlist is current, but which one a given row came from.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

/// Serialized: the stored-selection tests read and write
/// `PlaylistSelectionStore.key` / `ActiveProfileStore.current` in
/// `UserDefaults.standard`, shared process-wide state.
@MainActor
@Suite(.serialized)
struct QuickSwitchResolverTests {
    /// Added in the order given, a second apart — the fallback orders by
    /// `addedAt`, and back-to-back `Date()`s could tie.
    private func makePlaylists(_ names: [String], in context: ModelContext) throws -> [Playlist] {
        let playlists = names.map { Playlist(name: $0, serverURL: "http://\($0)", username: "u", password: "p") }
        for (offset, playlist) in playlists.enumerated() {
            playlist.addedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(offset))
            context.insert(playlist)
        }
        try context.save()
        return playlists
    }

    private func makeProfiles(_ names: [String], in context: ModelContext) throws -> [UserProfile] {
        let profiles = names.enumerated().map { UserProfile(name: $0.element, sortOrder: $0.offset) }
        for profile in profiles {
            context.insert(profile)
        }
        try context.save()
        return profiles
    }

    // MARK: - owner(ofContentID:)

    @Test func `content resolves to the playlist whose prefix it carries`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)
        let id = "\(playlists[1].id.uuidString)-live-4021"

        #expect(playlists.owner(ofContentID: id)?.id == playlists[1].id)
    }

    @Test func `content from a playlist that is gone owns nothing`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)

        #expect(playlists.owner(ofContentID: "\(UUID().uuidString)-live-4021") == nil)
    }

    @Test func `the owner is independent of which playlist is active`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)
        let id = "\(playlists[1].id.uuidString)-movie-77"

        // The active playlist is First; the row is still Second's to play.
        #expect(playlists.active(for: playlists[0].id.uuidString)?.id == playlists[0].id)
        #expect(playlists.owner(ofContentID: id)?.id == playlists[1].id)
    }

    // MARK: - active(for:)

    @Test func `an empty stored selection resolves to the oldest playlist`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)

        #expect(playlists.active(for: "")?.id == playlists[0].id)
    }

    @Test func `a stored selection naming a deleted playlist falls back to the oldest`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)

        #expect(playlists.active(for: UUID().uuidString)?.id == playlists[0].id)
    }

    @Test func `the fallback is the oldest playlist whatever order the fetch returned`() throws {
        // Every caller resolves against its own unsorted `@Query` or fetch; they
        // must still agree on the fallback.
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second", "Third"], in: container.mainContext)

        #expect(Array(playlists.reversed()).active(for: "")?.id == playlists[0].id)
        #expect([playlists[1], playlists[0], playlists[2]].scope(for: UUID().uuidString, isPremium: false).selectionID
            == playlists[0].id.uuidString)
    }

    @Test func `a valid stored selection resolves to that playlist`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second", "Third"], in: container.mainContext)

        #expect(playlists.active(for: playlists[2].id.uuidString)?.id == playlists[2].id)
    }

    @Test func `no playlists resolves to nothing`() {
        #expect([Playlist]().active(for: UUID().uuidString) == nil)
    }

    // MARK: - Playlist rows

    @Test func `playlist rows keep the given order and mark the stored selection current`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second", "Third"], in: container.mainContext)

        let scope = playlists.scope(for: playlists[1].id.uuidString, isPremium: false)
        let rows = QuickSwitchResolver.playlistRows(playlists, scope: scope)

        #expect(rows.map(\.item.name) == ["First", "Second", "Third"])
        #expect(rows.filter(\.isCurrent).map(\.item.name) == ["Second"])
    }

    @Test func `playlist rows mark the first row current when the stored selection is stale`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)

        let scope = playlists.scope(for: UUID().uuidString, isPremium: false)
        let rows = QuickSwitchResolver.playlistRows(playlists, scope: scope)

        #expect(rows.filter(\.isCurrent).map(\.item.name) == ["First"])
        #expect(playlists.scope(for: "", isPremium: false).selectionID == playlists[0].id.uuidString)
    }

    @Test func `the current playlist follows the value in the selection store`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)

        let savedSelection = UserDefaults.standard.string(forKey: PlaylistSelectionStore.key)
        defer {
            if let savedSelection {
                UserDefaults.standard.set(savedSelection, forKey: PlaylistSelectionStore.key)
            } else {
                UserDefaults.standard.removeObject(forKey: PlaylistSelectionStore.key)
            }
        }

        UserDefaults.standard.set(playlists[1].id.uuidString, forKey: PlaylistSelectionStore.key)
        let stored = UserDefaults.standard.string(forKey: PlaylistSelectionStore.key) ?? ""

        #expect(playlists.active(for: stored)?.id == playlists[1].id)
    }

    // MARK: - Profile rows

    @Test func `profile rows keep the roster order and mark the active profile current`() throws {
        let container = try makeProfileTestContainer()
        let profiles = try makeProfiles(["Me", "Kids", "Guest"], in: container.mainContext)

        let rows = QuickSwitchResolver.profileRows(profiles, activeProfileID: profiles[2].id)

        #expect(rows.map(\.item.name) == ["Me", "Kids", "Guest"])
        #expect(rows.filter(\.isCurrent).map(\.item.name) == ["Guest"])
        #expect(QuickSwitchResolver.currentProfile(in: profiles, activeProfileID: profiles[2].id)?.id == profiles[2].id)
    }

    @Test func `an unknown active profile id makes no row current`() throws {
        let container = try makeProfileTestContainer()
        let profiles = try makeProfiles(["Me", "Kids"], in: container.mainContext)

        let rows = QuickSwitchResolver.profileRows(profiles, activeProfileID: UUID())

        #expect(rows.allSatisfy { !$0.isCurrent })
        #expect(QuickSwitchResolver.currentProfile(in: profiles, activeProfileID: UUID()) == nil)
    }

    @Test func `the current profile follows the active profile store`() throws {
        let container = try makeProfileTestContainer()
        let profiles = try makeProfiles(["Me", "Kids"], in: container.mainContext)

        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }

        ActiveProfileStore.current = profiles[1].id
        let active = ActiveProfileStore.current ?? UserProfile.defaultProfileID

        #expect(QuickSwitchResolver.currentProfile(in: profiles, activeProfileID: active)?.name == "Kids")
    }

    // MARK: - scope(for:isPremium:)

    private func makeMember(_ playlist: Playlist, priority: Int?, tabs: Set<PlaylistTab>) {
        playlist.combinedTabs = tabs
        playlist.combinedPriority = priority
    }

    @Test func `an isolated selection scopes to that playlist with every tab`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)

        let scope = playlists.scope(for: playlists[1].id.uuidString, isPremium: true)

        #expect(scope.playlistIDs == [playlists[1].id])
        #expect(!scope.isCombined)
        #expect(scope.token == playlists[1].id.uuidString)
        for tab in PlaylistTab.allCases {
            #expect(scope.members(for: tab) == [playlists[1].id])
        }
    }

    @Test func `an empty or stale selection scopes to the oldest playlist`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)

        #expect(playlists.scope(for: nil, isPremium: true).playlistIDs == [playlists[0].id])
        #expect(Array(playlists.reversed()).scope(for: UUID().uuidString, isPremium: true).playlistIDs == [playlists[0].id])
    }

    @Test func `no playlists resolve to the empty scope`() {
        let scope = [Playlist]().scope(for: PlaylistSelectionStore.combined, isPremium: true)

        #expect(scope == .empty)
        #expect(scope.isEmpty)
        #expect(scope.prefixes.isEmpty)
    }

    @Test func `combined members follow priority, then age, then id`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["A", "B", "C", "D"], in: container.mainContext)
        makeMember(playlists[0], priority: 2, tabs: [.movies])
        makeMember(playlists[1], priority: nil, tabs: [.series])
        makeMember(playlists[2], priority: 1, tabs: [.liveTV, .movies])
        makeMember(playlists[3], priority: nil, tabs: [.liveTV])

        let scope = Array(playlists.reversed()).scope(for: PlaylistSelectionStore.combined, isPremium: true)

        #expect(scope.isCombined)
        #expect(scope.playlistIDs == [playlists[2].id, playlists[0].id, playlists[1].id, playlists[3].id])
        #expect(scope.members(for: .movies) == [playlists[2].id, playlists[0].id])
        #expect(scope.members(for: .series) == [playlists[1].id])
        #expect(scope.members(for: .liveTV) == [playlists[2].id, playlists[3].id])
    }

    @Test func `combined skips non-members and unknown source types`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["A", "B", "C", "D"], in: container.mainContext)
        makeMember(playlists[0], priority: 1, tabs: [.movies])
        makeMember(playlists[1], priority: 2, tabs: [])
        makeMember(playlists[2], priority: 3, tabs: [.series])
        makeMember(playlists[3], priority: 4, tabs: [.liveTV])
        playlists[2].sourceTypeRaw = "from-a-newer-build"

        let scope = playlists.scope(for: PlaylistSelectionStore.combined, isPremium: true)

        #expect(scope.playlistIDs == [playlists[0].id, playlists[3].id])
    }

    @Test func `a playlist with sync turned off still contributes`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["A", "B"], in: container.mainContext)
        makeMember(playlists[0], priority: 1, tabs: [.liveTV])
        makeMember(playlists[1], priority: 2, tabs: [.movies])
        playlists[1].syncEnabled = false

        let scope = playlists.scope(for: PlaylistSelectionStore.combined, isPremium: true)

        #expect(scope.playlistIDs == [playlists[0].id, playlists[1].id])
    }

    @Test func `combined without pro falls back to the priority-1 member without writing`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["A", "B"], in: container.mainContext)
        makeMember(playlists[0], priority: 2, tabs: [.movies])
        makeMember(playlists[1], priority: 1, tabs: [.liveTV])
        try container.mainContext.save()

        let scope = playlists.scope(for: PlaylistSelectionStore.combined, isPremium: false)

        #expect(!scope.isCombined)
        #expect(scope.playlistIDs == [playlists[1].id])
        #expect(scope.members(for: .movies) == [playlists[1].id], "the fallback is the whole playlist")
        #expect(!container.mainContext.hasChanges)
        #expect(playlists.map(\.combinedTypesRaw) == ["movies", "liveTV"])
        #expect(playlists.map(\.combinedPriority) == [2, 1])
    }

    @Test func `combined with one member falls back to it`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["A", "B"], in: container.mainContext)
        makeMember(playlists[1], priority: 1, tabs: [.movies])

        let scope = playlists.scope(for: PlaylistSelectionStore.combined, isPremium: true)

        #expect(scope == .isolated(playlists[1].id))
    }

    @Test func `combined with no members falls back to the oldest playlist`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["A", "B"], in: container.mainContext)

        let scope = Array(playlists.reversed()).scope(for: PlaylistSelectionStore.combined, isPremium: true)

        #expect(scope == .isolated(playlists[0].id))
    }

    @Test func `the combined token changes with membership, order and types`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["A", "B"], in: container.mainContext)
        makeMember(playlists[0], priority: 1, tabs: [.movies])
        makeMember(playlists[1], priority: 2, tabs: [.liveTV])
        let combined = PlaylistSelectionStore.combined

        let base = playlists.scope(for: combined, isPremium: true).token
        #expect(base == Array(playlists.reversed()).scope(for: combined, isPremium: true).token)
        #expect(base != playlists[0].id.uuidString)

        playlists[1].combinedTabs = [.liveTV, .series]
        let retyped = playlists.scope(for: combined, isPremium: true).token
        #expect(retyped != base)

        playlists[0].combinedPriority = 3
        #expect(playlists.scope(for: combined, isPremium: true).token != retyped)
    }

    @Test func `contains checks the member prefix and the contributed type`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["A", "B", "C"], in: container.mainContext)
        makeMember(playlists[0], priority: 1, tabs: [.liveTV])
        makeMember(playlists[1], priority: 2, tabs: [.movies])

        let scope = playlists.scope(for: PlaylistSelectionStore.combined, isPremium: true)
        let live = "\(playlists[0].id.uuidString)-live-1"
        let movie = "\(playlists[1].id.uuidString)-movie-1"
        let matcher = CatalogScope.Matcher(scope)

        #expect(matcher.contains(live, .liveTV))
        #expect(!matcher.contains(live, .movies))
        #expect(matcher.contains(movie, .movies))
        #expect(!matcher.contains("\(playlists[2].id.uuidString)-movie-1", .movies))
        #expect(scope.prefixes(for: .movies) == ["\(playlists[1].id.uuidString)-"])
    }

    // MARK: - Deleting members

    @Test func `deleting a member below two falls back to the remaining one and keeps the stored selection`() throws {
        let container = try makeProfileTestContainer()
        let context = container.mainContext
        let playlists = try makePlaylists(["A", "B", "C"], in: context)
        makeMember(playlists[0], priority: 1, tabs: [.liveTV])
        makeMember(playlists[1], priority: 2, tabs: [.movies])
        try context.save()

        let savedSelection = UserDefaults.standard.string(forKey: PlaylistSelectionStore.key)
        defer {
            if let savedSelection {
                UserDefaults.standard.set(savedSelection, forKey: PlaylistSelectionStore.key)
            } else {
                UserDefaults.standard.removeObject(forKey: PlaylistSelectionStore.key)
            }
        }
        UserDefaults.standard.set(PlaylistSelectionStore.combined, forKey: PlaylistSelectionStore.key)
        let stored = UserDefaults.standard.string(forKey: PlaylistSelectionStore.key)
        #expect(playlists.scope(for: stored, isPremium: true).isCombined)

        let survivorID = playlists[1].id
        PlaylistDeletion.delete(playlists[0], in: context)
        try context.save()
        let remaining = try context.fetch(FetchDescriptor<Playlist>())

        let scope = remaining.scope(for: stored, isPremium: true)
        #expect(scope == .isolated(survivorID))
        #expect(remaining.primaryMember(of: scope)?.id == survivorID)
        #expect(UserDefaults.standard.string(forKey: PlaylistSelectionStore.key) == PlaylistSelectionStore.combined)

        try PlaylistDeletion.delete(#require(remaining.first { $0.id == survivorID }), in: context)
        try context.save()
        let lastOne = try context.fetch(FetchDescriptor<Playlist>())

        #expect(lastOne.scope(for: stored, isPremium: true) == .isolated(playlists[2].id), "no member left: the oldest playlist")

        for playlist in lastOne {
            PlaylistDeletion.delete(playlist, in: context)
        }
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Playlist>()).scope(for: stored, isPremium: true) == .empty)
    }

    @Test func `deleting one of three members keeps the other two combined`() throws {
        let container = try makeProfileTestContainer()
        let context = container.mainContext
        let playlists = try makePlaylists(["A", "B", "C"], in: context)
        makeMember(playlists[0], priority: 1, tabs: [.liveTV])
        makeMember(playlists[1], priority: 2, tabs: [.movies])
        makeMember(playlists[2], priority: 3, tabs: [.series])
        try context.save()

        PlaylistDeletion.delete(playlists[1], in: context)
        try context.save()
        let remaining = try context.fetch(FetchDescriptor<Playlist>())

        let scope = remaining.scope(for: PlaylistSelectionStore.combined, isPremium: true)
        #expect(scope.isCombined)
        #expect(scope.playlistIDs == [playlists[0].id, playlists[2].id])
        #expect(scope.members(for: .movies).isEmpty)
    }

    // MARK: - Row identity

    @Test func `row ids are the item ids the focus targets key on`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)
        let profiles = try makeProfiles(["Me", "Kids"], in: container.mainContext)

        let playlistRows = QuickSwitchResolver.playlistRows(playlists, scope: playlists.scope(for: "", isPremium: false))
        let profileRows = QuickSwitchResolver.profileRows(profiles, activeProfileID: profiles[0].id)

        #expect(playlistRows.map(\.id) == playlists.map(\.id))
        #expect(profileRows.map(\.id) == profiles.map(\.id))
    }
}

// MARK: - Combined entry

/// The Combined row atop every playlist column: whether it is current, and
/// what picking it does.
extension QuickSwitchResolverTests {
    @Test func `combined in effect marks the combined entry current and no playlist row`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["A", "B"], in: container.mainContext)
        makeMember(playlists[0], priority: 1, tabs: [.movies])
        makeMember(playlists[1], priority: 2, tabs: [.liveTV])
        let scope = playlists.scope(for: PlaylistSelectionStore.combined, isPremium: true)

        let column = QuickSwitchResolver.playlistColumn(playlists, scope: scope, isPremium: true)

        #expect(column.isCombinedCurrent)
        #expect(column.rows.allSatisfy { !$0.isCurrent })
        #expect(column.combinedAction == .alreadyCurrent)
        #expect(column.combinedMemberNames == ["A", "B"])
    }

    @Test func `an isolated selection marks its playlist current, not the combined entry`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["A", "B"], in: container.mainContext)
        makeMember(playlists[0], priority: 2, tabs: [.movies])
        makeMember(playlists[1], priority: 1, tabs: [.liveTV])
        let scope = playlists.scope(for: playlists[0].id.uuidString, isPremium: true)

        let column = QuickSwitchResolver.playlistColumn(playlists, scope: scope, isPremium: true)

        #expect(!column.isCombinedCurrent)
        #expect(column.rows.map(\.isCurrent) == [true, false])
        #expect(column.combinedAction == .switchToCombined)
        #expect(column.combinedMemberNames == ["B", "A"], "members read in priority order")
    }

    @Test func `a lapsed combined selection opens the paywall and marks the fallback current`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["A", "B"], in: container.mainContext)
        makeMember(playlists[0], priority: 2, tabs: [.movies])
        makeMember(playlists[1], priority: 1, tabs: [.liveTV])
        let scope = playlists.scope(for: PlaylistSelectionStore.combined, isPremium: false)

        let column = QuickSwitchResolver.playlistColumn(playlists, scope: scope, isPremium: false)

        #expect(!column.isCombinedCurrent)
        #expect(column.rows.map(\.isCurrent) == [false, true])
        #expect(column.combinedAction == .paywall)
        #expect(column.combinedMemberNames == ["B", "A"], "a lapsed config still reads as configured")
    }

    @Test func `the paywall comes before configuring, even with no members`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["A", "B"], in: container.mainContext)
        let scope = playlists.scope(for: "", isPremium: false)

        #expect(QuickSwitchResolver.combinedAction(playlists, scope: scope, isPremium: false) == .paywall)
    }

    @Test func `pro with fewer than two members configures instead of switching`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["A", "B"], in: container.mainContext)
        makeMember(playlists[1], priority: 1, tabs: [.movies])
        let scope = playlists.scope(for: PlaylistSelectionStore.combined, isPremium: true)

        let column = QuickSwitchResolver.playlistColumn(playlists, scope: scope, isPremium: true)

        #expect(column.combinedAction == .configure)
        #expect(!column.isCombinedCurrent)
        #expect(column.rows.map(\.isCurrent) == [false, true], "the single member is what is in effect")
        #expect(column.combinedMemberNames == ["B"])
    }
}

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
    private func makePlaylists(_ names: [String], in context: ModelContext) throws -> [Playlist] {
        let playlists = names.map { Playlist(name: $0, serverURL: "http://\($0)", username: "u", password: "p") }
        for playlist in playlists {
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

    @Test func `an empty stored selection resolves to the first playlist`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)

        #expect(playlists.active(for: "")?.id == playlists[0].id)
    }

    @Test func `a stored selection naming a deleted playlist falls back to the first`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)

        #expect(playlists.active(for: UUID().uuidString)?.id == playlists[0].id)
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

        let rows = QuickSwitchResolver.playlistRows(playlists, storedID: playlists[1].id.uuidString)

        #expect(rows.map(\.item.name) == ["First", "Second", "Third"])
        #expect(rows.filter(\.isCurrent).map(\.item.name) == ["Second"])
    }

    @Test func `playlist rows mark the first row current when the stored selection is stale`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)

        let rows = QuickSwitchResolver.playlistRows(playlists, storedID: UUID().uuidString)

        #expect(rows.filter(\.isCurrent).map(\.item.name) == ["First"])
        #expect(playlists.activeID(for: "") == playlists[0].id.uuidString)
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

    // MARK: - Row identity

    @Test func `row ids are the item ids the focus targets key on`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)
        let profiles = try makeProfiles(["Me", "Kids"], in: container.mainContext)

        let playlistRows = QuickSwitchResolver.playlistRows(playlists, storedID: "")
        let profileRows = QuickSwitchResolver.profileRows(profiles, activeProfileID: profiles[0].id)

        #expect(playlistRows.map(\.id) == playlists.map(\.id))
        #expect(profileRows.map(\.id) == profiles.map(\.id))
    }
}

//
//  CloudSyncPlaylistCombinedTests.swift
//  LumeTests
//
//  A playlist's Combined View membership (content types + priority) rides the
//  playlist config through iCloud sync.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CloudSyncPlaylistCombinedTests {
    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "cloudsync.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    @Test func `playlist config decodes a baseline written before combined playlists existed`() throws {
        let legacy = #"{"name":"P","serverURL":"a","username":"u","password":"p","sourceTypeRaw":"xtream","syncEnabled":true,"hiddenTabsRaw":"movies"}"#
        let decoded = try JSONDecoder().decode(PlaylistConfigValues.self, from: Data(legacy.utf8))
        #expect(decoded.hiddenTabsRaw == "movies")
        #expect(decoded.combinedTypesRaw.isEmpty)
        #expect(decoded.combinedPriority == nil)
    }

    @Test func `playlist config round-trips the combined fields`() throws {
        let value = PlaylistConfigValues(
            name: "P", serverURL: "a", username: "u", password: "p",
            sourceTypeRaw: "xtream", epgURL: nil, syncEnabled: true,
            combinedTypesRaw: PlaylistTab.encode([.liveTV, .series]), combinedPriority: 2
        )
        let decoded = try JSONDecoder().decode(PlaylistConfigValues.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test func `combined membership syncs in both directions`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        playlist.combinedTabs = [.liveTV, .movies]
        playlist.combinedPriority = 0
        ctx.insert(playlist)
        try ctx.save()

        let shadow = freshShadow()
        _ = await CloudSyncEngine(container: container, shadow: shadow).reconcile()

        let mirror = try #require(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).first)
        #expect(mirror.combinedTypesRaw == PlaylistTab.encode([.liveTV, .movies]))
        #expect(mirror.combinedPriority == 0)

        // Another device moves it to second place and switches Movies for Series.
        mirror.combinedTypesRaw = PlaylistTab.encode([.series])
        mirror.combinedPriority = 1
        try ctx.save()
        _ = await CloudSyncEngine(container: container, shadow: shadow).reconcile()

        let local = try #require(try ctx.fetch(FetchDescriptor<Playlist>()).first)
        #expect(local.combinedTabs == [.series])
        #expect(local.combinedPriority == 1)
    }

    @Test func `switching every type off keeps the priority on both sides`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        playlist.combinedTabs = [.liveTV]
        playlist.combinedPriority = 3
        ctx.insert(playlist)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await engine.reconcile()

        playlist.combinedTabs = []
        try ctx.save()
        _ = await engine.reconcile()

        let mirror = try #require(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).first)
        #expect(mirror.combinedTypesRaw.isEmpty)
        #expect(mirror.combinedPriority == 3)
    }

    @Test func `a new device creates its playlist with the mirrored combined config`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let pid = UUID()
        ctx.insert(SyncedPlaylist(
            id: pid, name: "Remote", serverURL: "http://r", username: "ru", password: "rp",
            sourceTypeRaw: "xtream", epgURL: nil, syncEnabled: true,
            combinedTypesRaw: PlaylistTab.encode([.movies, .series]), combinedPriority: 1
        ))
        try ctx.save()

        let result = await CloudSyncEngine(container: container, shadow: freshShadow()).reconcile()

        #expect(result.playlistsCreatedLocally == 1)
        let local = try #require(try ctx.fetch(FetchDescriptor<Playlist>()).first)
        #expect(local.id == pid)
        #expect(local.combinedTabs == [.movies, .series])
        #expect(local.combinedPriority == 1)
        #expect(local.isCombinedMember)
    }

    @Test func `a re-baseline pass leaves a matching combined mirror untouched`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        playlist.combinedTabs = [.liveTV, .series]
        playlist.combinedPriority = 0
        ctx.insert(playlist)
        try ctx.save()

        _ = await CloudSyncEngine(container: container, shadow: freshShadow()).reconcile()
        let mirror = try #require(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).first)
        let stamped = mirror.updatedAt

        // A fresh shadow: local and cloud agree, and there is no baseline yet.
        _ = await CloudSyncEngine(container: container, shadow: freshShadow()).reconcile()

        let after = try #require(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).first)
        #expect(after.updatedAt == stamped)
        #expect(after.combinedTypesRaw == PlaylistTab.encode([.liveTV, .series]))
        #expect(after.combinedPriority == 0)
    }
}

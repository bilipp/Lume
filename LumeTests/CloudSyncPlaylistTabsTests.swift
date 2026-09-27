//
//  CloudSyncPlaylistTabsTests.swift
//  LumeTests
//
//  A playlist's hidden tabs (Settings › Library › Tabs) ride the playlist
//  config through iCloud sync.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CloudSyncPlaylistTabsTests {
    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "cloudsync.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    @Test func `playlist config decodes a baseline written before hidden tabs existed`() throws {
        let legacy = #"{"name":"P","serverURL":"a","username":"u","password":"p","sourceTypeRaw":"xtream","syncEnabled":true}"#
        let decoded = try JSONDecoder().decode(PlaylistConfigValues.self, from: Data(legacy.utf8))
        #expect(decoded.name == "P")
        #expect(decoded.hiddenTabsRaw.isEmpty)
    }

    @Test func `hidden tabs sync in both directions`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        playlist.hiddenTabs = [.liveTV]
        ctx.insert(playlist)
        try ctx.save()

        let shadow = freshShadow()
        _ = await CloudSyncEngine(container: container, shadow: shadow).reconcile()

        let mirror = try #require(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).first)
        #expect(mirror.hiddenTabsRaw == "liveTV")

        // Another device hides Movies and Series instead. A fresh engine, so its
        // context reads the edited mirror rather than the one it registered.
        mirror.hiddenTabsRaw = PlaylistTab.encode([.movies, .series])
        try ctx.save()
        _ = await CloudSyncEngine(container: container, shadow: shadow).reconcile()

        let local = try #require(try ctx.fetch(FetchDescriptor<Playlist>()).first)
        #expect(local.hiddenTabs == [.movies, .series])
    }
}

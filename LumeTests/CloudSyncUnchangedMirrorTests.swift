//
//  CloudSyncUnchangedMirrorTests.swift
//  LumeTests
//
//  A reconcile that has nothing new to say must not rewrite cloud mirrors.
//  Every rewrite bumps `updatedAt`, which makes CloudKit export the record and
//  every other device on the account import it again.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CloudSyncUnchangedMirrorTests {
    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "cloudsync.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    @Test func `a re-baseline pass leaves matching mirrors untouched`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext

        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        let pid = playlist.id
        ctx.insert(playlist)
        let movie = Movie(id: "\(pid.uuidString)-movie-1", streamId: 1, name: "Film")
        movie.isFavorite = true
        movie.watchProgress = 42
        ctx.insert(movie)
        try ctx.save()

        _ = await CloudSyncEngine(container: container, shadow: freshShadow()).reconcile()
        let mirror = try #require(try ctx.fetch(FetchDescriptor<UserContentState>()).first)
        let stamped = mirror.updatedAt

        // A new shadow is what the pass after a profile switch starts from:
        // local and cloud agree, and there is no baseline yet.
        _ = await CloudSyncEngine(container: container, shadow: freshShadow()).reconcile()

        let after = try #require(try ctx.fetch(FetchDescriptor<UserContentState>()).first)
        #expect(after.updatedAt == stamped)
        #expect(after.isFavorite == true)
        #expect(after.watchProgress == 42)
    }

    @Test func `a changed value still rewrites its mirror`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let shadow = freshShadow()

        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        let pid = playlist.id
        ctx.insert(playlist)
        let movie = Movie(id: "\(pid.uuidString)-movie-1", streamId: 1, name: "Film")
        movie.watchProgress = 10
        ctx.insert(movie)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: shadow)
        _ = await engine.reconcile()

        movie.watchProgress = 90
        try ctx.save()
        _ = await engine.reconcile()

        let mirror = try #require(try ctx.fetch(FetchDescriptor<UserContentState>()).first)
        #expect(mirror.watchProgress == 90)
    }
}

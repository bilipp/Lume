//
//  CloudSyncPrunedStateTests.swift
//  LumeTests
//
//  A catalog prune must never read as the user clearing their state: the
//  reconcile keeps a pruned title's cloud record and re-applies it when the
//  title returns, while a real clear on a row that still exists still deletes.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CloudSyncPrunedStateTests {
    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "cloudsync.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    @Test func `a pruned favorite keeps its cloud state and returns with the title`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let shadow = freshShadow()

        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        let pid = playlist.id
        ctx.insert(playlist)
        let movieId = "\(pid.uuidString)-movie-12345"
        let favorite = Movie(id: movieId, streamId: 12345, name: "Film")
        favorite.isFavorite = true
        ctx.insert(favorite)
        // A second row keeps the catalog non-empty, so the integrity gate stays open.
        ctx.insert(Movie(id: "\(pid.uuidString)-movie-2", streamId: 2, name: "Other"))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: shadow)
        _ = await engine.reconcile()
        #expect(try ctx.fetch(FetchDescriptor<UserContentState>()).count == 1)

        // The provider drops the title and the sync prunes its row.
        ctx.delete(favorite)
        try ctx.save()

        let afterPrune = await engine.reconcile()
        #expect(afterPrune.contentPending == 1)
        #expect(try ctx.fetch(FetchDescriptor<UserContentState>()).first?.isFavorite == true)

        // Later passes stay pending instead of pushing a deletion.
        _ = await engine.reconcile()
        #expect(try ctx.fetch(FetchDescriptor<UserContentState>()).count == 1)

        // The title comes back in a later sync, with default local state.
        ctx.insert(Movie(id: movieId, streamId: 12345, name: "Film"))
        try ctx.save()

        let afterReturn = await engine.reconcile()
        #expect(afterReturn.contentPulled == 1)
        let restored = try ctx.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })).first
        #expect(restored?.isFavorite == true)
    }

    @Test func `clearing a favorite on a row that still exists deletes the cloud state`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let shadow = freshShadow()

        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        let pid = playlist.id
        ctx.insert(playlist)
        let movie = Movie(id: "\(pid.uuidString)-movie-1", streamId: 1, name: "Film")
        movie.isFavorite = true
        ctx.insert(movie)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: shadow)
        _ = await engine.reconcile()
        #expect(try ctx.fetch(FetchDescriptor<UserContentState>()).count == 1)

        movie.isFavorite = false
        try ctx.save()

        _ = await engine.reconcile()
        #expect(try ctx.fetch(FetchDescriptor<UserContentState>()).isEmpty)
    }
}

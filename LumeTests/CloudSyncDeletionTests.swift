//
//  CloudSyncDeletionTests.swift
//  LumeTests
//
//  Covers user-initiated playlist deletion through the sync engine (#136):
//  deleting the last playlist must clear the cloud mirror and the shadow
//  baselines in the same operation, so the empty-catalog integrity gate reads
//  the result as a fresh device instead of a lost store — and never pulls the
//  deleted playlist back.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CloudSyncDeletionTests {
    private func makeContainer() throws -> ModelContainer {
        let fullSchema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self,
            SyncedPlaylist.self, UserContentState.self, SyncedEPGSource.self
        ])
        // `cloudKitDatabase: .none` is required on both stores: the catalog uses
        // `@Attribute(.unique)`, which CloudKit forbids, and the default
        // `.automatic` mirrors to CloudKit on a signed/entitled test host and
        // fails the load with `loadIssueModelContainer`.
        let localConfig = ModelConfiguration(
            "local",
            schema: Schema([
                Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
                Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
            ]),
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let cloudConfig = ModelConfiguration(
            "cloud",
            schema: Schema([SyncedPlaylist.self, UserContentState.self, SyncedEPGSource.self]),
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: fullSchema, configurations: localConfig, cloudConfig)
    }

    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "cloudsync.deletion.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    @Test func `deleting the last playlist propagates to the cloud instead of resurrecting`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let shadow = freshShadow()

        // Seed a playlist + a favorite movie and reconcile once, so the cloud
        // mirrors and the shadow baselines exist — the state a long-synced
        // device is in when the user deletes their only playlist.
        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        let pid = playlist.id
        ctx.insert(playlist)
        let movie = Movie(id: "\(pid.uuidString)-movie-1", streamId: 1, name: "Film")
        movie.isFavorite = true
        ctx.insert(movie)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: shadow)
        _ = await engine.reconcile()
        #expect(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).count == 1)
        #expect(try ctx.fetch(FetchDescriptor<UserContentState>()).count == 1)

        try await engine.deletePlaylist(id: pid)

        // Everything is gone: catalog, cloud mirrors, and — critically — the
        // shadow baselines, so the empty catalog now reads as a fresh device.
        #expect(try ctx.fetch(FetchDescriptor<Playlist>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<Movie>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<UserContentState>()).isEmpty)

        // The next reconcile must not misread the empty catalog as a lost
        // store and pull the playlist back (the #136 resurrection loop).
        let result = await engine.reconcile()
        #expect(!result.recoveredFromEmptyLocalStore)
        #expect(result.playlistsCreatedLocally == 0)
        #expect(try ctx.fetch(FetchDescriptor<Playlist>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).isEmpty)
    }

    @Test func `deleting one of several playlists leaves the survivor untouched`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let doomed = Playlist(name: "Doomed", serverURL: "http://a", username: "u", password: "p")
        let survivor = Playlist(name: "Survivor", serverURL: "http://b", username: "u", password: "p")
        ctx.insert(doomed)
        ctx.insert(survivor)
        let favorite = Movie(id: "\(survivor.id.uuidString)-movie-1", streamId: 1, name: "Keeper")
        favorite.isFavorite = true
        ctx.insert(favorite)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await engine.reconcile()
        #expect(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).count == 2)

        try await engine.deletePlaylist(id: doomed.id)

        let mirrors = try ctx.fetch(FetchDescriptor<SyncedPlaylist>())
        #expect(mirrors.count == 1)
        #expect(mirrors.first?.id == survivor.id)
        let locals = try ctx.fetch(FetchDescriptor<Playlist>())
        #expect(locals.count == 1)
        #expect(locals.first?.id == survivor.id)
        #expect(try ctx.fetch(FetchDescriptor<UserContentState>()).count == 1)
    }

    @Test func `deleting a never-synced playlist works without a mirror or shadow`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let playlist = Playlist(name: "Local Only", serverURL: "http://x", username: "u", password: "p")
        let pid = playlist.id
        ctx.insert(playlist)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        try await engine.deletePlaylist(id: pid)

        #expect(try ctx.fetch(FetchDescriptor<Playlist>()).isEmpty)
    }
}

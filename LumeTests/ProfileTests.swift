//
//  ProfileTests.swift
//  LumeTests
//
//  Covers the profile-aware additions to the sync engine: launch bootstrap
//  (default profile + legacy-record migration + dedup), the active-profile
//  projection on switch, scoped reconciliation, and profile-data purge. Runs
//  against an in-memory two-configuration store (no CloudKit), like
//  CloudSyncTests.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

/// Serialized: the reconcile-scoping test reads the active profile from
/// `ActiveProfileStore` (UserDefaults.standard), shared process-wide state.
@MainActor
@Suite(.serialized)
struct ProfileEngineTests {
    private func makeContainer() throws -> ModelContainer {
        let fullSchema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self,
            SyncedPlaylist.self, UserContentState.self, UserProfile.self
        ])
        let localConfig = ModelConfiguration(
            "local",
            schema: Schema([
                Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
                Series.self, Episode.self, CastMember.self, EPGListing.self
            ]),
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let cloudConfig = ModelConfiguration(
            "cloud",
            schema: Schema([SyncedPlaylist.self, UserContentState.self, UserProfile.self]),
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: fullSchema, configurations: localConfig, cloudConfig)
    }

    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "profiles.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    @Test func `bootstrap creates a default profile and claims legacy records`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        ctx.insert(UserContentState(contentId: "pl-movie-1", kind: .movie, isFavorite: true))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = try await engine.bootstrapProfiles(preferredActiveID: nil, defaultName: "Default")

        #expect(result.activeProfileID == UserProfile.defaultProfileID)
        #expect(result.profileCount == 1)

        let profiles = try ctx.fetch(FetchDescriptor<UserProfile>())
        #expect(profiles.count == 1)

        let states = try ctx.fetch(FetchDescriptor<UserContentState>())
        #expect(states.first?.profileID == UserProfile.defaultProfileID)
    }

    @Test func `bootstrap collapses duplicate default profiles keeping the earliest`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        ctx.insert(UserProfile(id: UserProfile.defaultProfileID, name: "First", createdAt: Date(timeIntervalSince1970: 100)))
        ctx.insert(UserProfile(id: UserProfile.defaultProfileID, name: "Second", createdAt: Date(timeIntervalSince1970: 200)))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = try await engine.bootstrapProfiles(preferredActiveID: nil, defaultName: "Default")

        #expect(result.profileCount == 1)
        let profiles = try ctx.fetch(FetchDescriptor<UserProfile>())
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == "First")
    }

    @Test func `reconcile collapses a duplicate default profile imported from another device`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        // Simulates a freshly-synced device: its own bootstrap-created default
        // profile, plus the original device's default (same fixed id) that
        // CloudKit has just imported. They share an id but are distinct rows.
        ctx.insert(UserProfile(id: UserProfile.defaultProfileID, name: "Original", createdAt: Date(timeIntervalSince1970: 100)))
        ctx.insert(UserProfile(id: UserProfile.defaultProfileID, name: "This Device", createdAt: Date(timeIntervalSince1970: 200)))
        // A non-default profile must survive untouched.
        let keeper = UUID()
        ctx.insert(UserProfile(id: keeper, name: "Kids", createdAt: Date(timeIntervalSince1970: 150)))
        try ctx.save()

        let saved = ActiveProfileStore.current
        ActiveProfileStore.current = UserProfile.defaultProfileID
        defer { ActiveProfileStore.current = saved }

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await engine.reconcile()

        let profiles = try ctx.fetch(FetchDescriptor<UserProfile>())
        // One default (the earliest) plus the untouched non-default profile.
        #expect(profiles.count == 2)
        let defaults = profiles.filter { $0.id == UserProfile.defaultProfileID }
        #expect(defaults.count == 1)
        #expect(defaults.first?.name == "Original")
        #expect(profiles.contains { $0.id == keeper })
    }

    @Test func `switching profiles flushes the old profile and hydrates the new`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profileA = UUID()
        let profileB = UUID()

        let movie = Movie(id: "pl-movie-1", streamId: 1, name: "Film")
        movie.isFavorite = true
        movie.watchProgress = 100
        ctx.insert(movie)
        // Profile B already has its own saved state for the same movie.
        ctx.insert(UserContentState(
            contentId: "pl-movie-1", kind: .movie, profileID: profileB,
            watchProgress: 500, isWatched: true
        ))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        try await engine.switchProfile(from: profileA, to: profileB)

        // Profile A's state was flushed into a mirror.
        let states = try ctx.fetch(FetchDescriptor<UserContentState>())
        let aMirror = states.first { $0.profileID == profileA }
        #expect(aMirror?.isFavorite == true)
        #expect(aMirror?.watchProgress == 100)

        // The catalog now projects profile B.
        let projected = try ctx.fetch(FetchDescriptor<Movie>()).first
        #expect(projected?.isFavorite == false)
        #expect(projected?.isWatched == true)
        #expect(projected?.watchProgress == 500)
    }

    @Test func `reconcile only projects the active profile's mirrors`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profileA = UUID()
        let profileB = UUID()
        let pid = UUID()
        let movieId = "\(pid.uuidString)-movie-1"

        let playlist = Playlist(name: "PL", serverURL: "http://x", username: "u", password: "p")
        playlist.id = pid
        ctx.insert(playlist)
        ctx.insert(Movie(id: movieId, streamId: 1, name: "Film"))
        // An inactive profile (B) favorited this movie; it must NOT leak onto the
        // catalog while profile A is active.
        ctx.insert(UserContentState(contentId: movieId, kind: .movie, profileID: profileB, isFavorite: true))
        try ctx.save()

        let saved = ActiveProfileStore.current
        ActiveProfileStore.current = profileA
        defer { ActiveProfileStore.current = saved }

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await engine.reconcile()

        let movie = try ctx.fetch(FetchDescriptor<Movie>()).first
        #expect(movie?.isFavorite == false)
        // B's mirror is untouched (still belongs to B).
        let bMirror = try ctx.fetch(FetchDescriptor<UserContentState>()).first { $0.profileID == profileB }
        #expect(bMirror?.isFavorite == true)
    }

    @Test func `purging a profile deletes only its records`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profileA = UUID()
        let profileB = UUID()
        ctx.insert(UserContentState(contentId: "m1", kind: .movie, profileID: profileA, isFavorite: true))
        ctx.insert(UserContentState(contentId: "m2", kind: .movie, profileID: profileB, isFavorite: true))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        try await engine.purgeProfileData(profileA)

        let remaining = try ctx.fetch(FetchDescriptor<UserContentState>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.profileID == profileB)
    }
}

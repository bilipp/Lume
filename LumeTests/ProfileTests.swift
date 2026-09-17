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
    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "profiles.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    @Test func `bootstrap creates a default profile and claims legacy records`() async throws {
        let container = try makeProfileTestContainer()
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
        let container = try makeProfileTestContainer()
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
        let container = try makeProfileTestContainer()
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
        let container = try makeProfileTestContainer()
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

        // `switchProfile` now commits the new active profile to `ActiveProfileStore`
        // atomically with the swap; save/restore it so this serialized suite
        // doesn't leak the change into other tests.
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        try await engine.switchProfile(from: profileA, to: profileB)
        #expect(ActiveProfileStore.current == profileB)

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
        let container = try makeProfileTestContainer()
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
        let container = try makeProfileTestContainer()
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

    // MARK: - ProfileManager switch contract

    /// A `ProfileManager` over the in-memory two-configuration container (the
    /// catalog and cloud stores are two configurations of the same container).
    /// The coordinator runs with `cloudKitEnabled: false`: touching `CKContainer`
    /// from an un-entitled test binary crashes, and that path still reconciles
    /// the local store.
    private func makeManager(_ container: ModelContainer) -> (ProfileManager, CloudSyncCoordinator) {
        let coordinator = CloudSyncCoordinator(
            catalogContainer: container,
            cloudContainer: container,
            cloudKitContainerIdentifier: "iCloud.lume.tests.invalid",
            cloudKitEnabled: false
        )
        let manager = ProfileManager(
            catalogContainer: container,
            cloudContainer: container,
            coordinator: coordinator
        )
        return (manager, coordinator)
    }

    /// Starts a switch and returns once it has reached its first suspension
    /// point, so the caller can observe the in-flight state.
    private func beginSwitch(_ manager: ProfileManager, to id: UUID) async -> Task<Void, Never> {
        let task = Task { await manager.switchProfile(to: id) }
        var spins = 0
        while !manager.isSwitching, spins < 500 {
            await Task.yield()
            spins += 1
        }
        return task
    }

    /// A reconcile is debounced by 600 ms and coalesces, so its only observable
    /// trace is `status.lastReconcile` moving on. Polls rather than sleeping a
    /// fixed amount; `attempts` is kept short when asserting that none arrives.
    private func waitForReconcile(
        _ coordinator: CloudSyncCoordinator,
        after previous: Date?,
        attempts: Int = 100
    ) async -> Date? {
        for _ in 0 ..< attempts {
            if let date = coordinator.status.lastReconcile, date != previous {
                return date
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @Test func `switching to the already-active profile is a no-op`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let active = UUID()
        ctx.insert(UserProfile(id: active, name: "Me", createdAt: Date(timeIntervalSince1970: 100)))
        try ctx.save()

        let saved = ActiveProfileStore.current
        ActiveProfileStore.current = active
        defer { ActiveProfileStore.current = saved }

        let (manager, coordinator) = makeManager(container)
        #expect(manager.activeProfileID == active)

        await manager.switchProfile(to: active)

        #expect(manager.isSwitching == false)
        #expect(manager.pendingProfileName == nil)
        #expect(manager.activeProfileID == active)
        // No switch work ran, so the trailing re-baselining reconcile never fired.
        let reconciled = await waitForReconcile(coordinator, after: nil, attempts: 20)
        #expect(reconciled == nil)
    }

    @Test func `a switch already in flight refuses a second target`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let profileA = UUID()
        let profileB = UUID()
        let profileC = UUID()
        ctx.insert(UserProfile(id: profileA, name: "A", createdAt: Date(timeIntervalSince1970: 100)))
        ctx.insert(UserProfile(id: profileB, name: "B", createdAt: Date(timeIntervalSince1970: 200)))
        ctx.insert(UserProfile(id: profileC, name: "C", createdAt: Date(timeIntervalSince1970: 300)))
        try ctx.save()

        let saved = ActiveProfileStore.current
        ActiveProfileStore.current = profileA
        defer { ActiveProfileStore.current = saved }

        let (manager, _) = makeManager(container)
        let switching = await beginSwitch(manager, to: profileB)
        #expect(manager.isSwitching)

        await manager.switchProfile(to: profileC)
        #expect(manager.pendingProfileName == "B")

        await switching.value
        #expect(manager.activeProfileID == profileB)
        #expect(ActiveProfileStore.current == profileB)
    }

    @Test func `pendingProfileName holds the target while switching and clears after`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let profileA = UUID()
        let profileB = UUID()
        ctx.insert(UserProfile(id: profileA, name: "Grown-ups", createdAt: Date(timeIntervalSince1970: 100)))
        ctx.insert(UserProfile(id: profileB, name: "Kids", createdAt: Date(timeIntervalSince1970: 200)))
        try ctx.save()

        let saved = ActiveProfileStore.current
        ActiveProfileStore.current = profileA
        defer { ActiveProfileStore.current = saved }

        let (manager, _) = makeManager(container)
        #expect(manager.pendingProfileName == nil)

        let switching = await beginSwitch(manager, to: profileB)
        #expect(manager.pendingProfileName == "Kids")

        await switching.value
        #expect(manager.isSwitching == false)
        #expect(manager.pendingProfileName == nil)
    }

    @Test func `a profile switch flushes pending catalog edits before exporting`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        // Autosave off so "unsaved" stays unsaved: the only save in this test is
        // the flush at the top of `switchProfile`, which is what's under test.
        ctx.autosaveEnabled = false
        let profileA = UUID()
        let profileB = UUID()
        ctx.insert(UserProfile(id: profileA, name: "A", createdAt: Date(timeIntervalSince1970: 100)))
        ctx.insert(UserProfile(id: profileB, name: "B", createdAt: Date(timeIntervalSince1970: 200)))
        try ctx.save()

        let saved = ActiveProfileStore.current
        ActiveProfileStore.current = profileA
        defer { ActiveProfileStore.current = saved }

        let (manager, _) = makeManager(container)

        // A favorite toggled moments ago that no save has reached yet. Without the
        // flush the engine's background context exports a stale catalog and this
        // state is lost instead of landing in profile A's mirror.
        let movie = Movie(id: "pl-movie-1", streamId: 1, name: "Film")
        movie.isFavorite = true
        movie.watchProgress = 100
        ctx.insert(movie)

        await manager.switchProfile(to: profileB)

        let mirror = try ctx.fetch(FetchDescriptor<UserContentState>()).first { $0.profileID == profileA }
        #expect(mirror?.isFavorite == true)
        #expect(mirror?.watchProgress == 100)
    }

    @Test func `exactly one reconcile follows a profile switch`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let profileA = UUID()
        let profileB = UUID()
        ctx.insert(UserProfile(id: profileA, name: "A", createdAt: Date(timeIntervalSince1970: 100)))
        ctx.insert(UserProfile(id: profileB, name: "B", createdAt: Date(timeIntervalSince1970: 200)))
        try ctx.save()

        let saved = ActiveProfileStore.current
        ActiveProfileStore.current = profileA
        defer { ActiveProfileStore.current = saved }

        let (manager, coordinator) = makeManager(container)
        #expect(coordinator.status.lastReconcile == nil)

        await manager.switchProfile(to: profileB)

        let first = await waitForReconcile(coordinator, after: nil)
        #expect(first != nil)
        // The re-baselining pass is the only one the switch queues; a second
        // would move `lastReconcile` on again.
        let second = await waitForReconcile(coordinator, after: first, attempts: 20)
        #expect(second == nil)
    }
}

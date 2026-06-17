//
//  CloudSyncTests.swift
//  LumeTests
//
//  Covers the iCloud-sync reconciler: the pure three-way merge (create / update
//  / delete in both directions, conflict policy) and the engine end-to-end
//  against an in-memory two-configuration store (no CloudKit needed).
//

import Foundation
@testable import Lume
import SwiftData
import Testing

// MARK: - Pure three-way merge

struct CloudSyncMergeTests {
    private func merge(
        _ local: Int?, _ cloud: Int?, _ shadow: Int?
    ) -> MergeVerdict<Int> {
        CloudSyncMerge.reconcile(local: local, cloud: cloud, shadow: shadow) { lhs, _ in lhs }
    }

    @Test func `nothing changed is a no-op`() {
        #expect(merge(5, 5, 5) == .noChange)
        #expect(merge(nil, nil, nil) == .noChange)
    }

    @Test func `local create pushes to cloud`() {
        #expect(merge(7, nil, nil) == .pushToCloud(7))
    }

    @Test func `cloud create pulls to local`() {
        #expect(merge(nil, 7, nil) == .pullToLocal(7))
    }

    @Test func `local edit pushes to cloud`() {
        #expect(merge(9, 5, 5) == .pushToCloud(9))
    }

    @Test func `cloud edit pulls to local`() {
        #expect(merge(5, 9, 5) == .pullToLocal(9))
    }

    @Test func `local delete pushes deletion to cloud`() {
        #expect(merge(nil, 5, 5) == .pushToCloud(nil))
    }

    @Test func `cloud delete pulls deletion to local`() {
        #expect(merge(5, nil, 5) == .pullToLocal(nil))
    }

    @Test func `both sides converged on the same value just re-baselines`() {
        #expect(merge(8, 8, 3) == .pushToCloud(8))
    }

    @Test func `genuine conflict invokes the merge closure`() {
        // local edited to 10, cloud edited to 20, base was 5.
        let verdict = CloudSyncMerge.reconcile(local: 10, cloud: 20, shadow: 5) { lhs, rhs in lhs + rhs }
        #expect(verdict == .writeBoth(30))
    }

    @Test func `edit versus delete preserves the surviving edit`() {
        // local edited 5→10, cloud deleted (now nil). Both moved from the base,
        // so it's a conflict; keep the surviving edit (un-delete) on both sides.
        #expect(merge(10, nil, 5) == .writeBoth(10))
        #expect(merge(nil, 10, 5) == .writeBoth(10))
    }
}

// MARK: - Conflict policies

struct CloudSyncConflictPolicyTests {
    @Test func `content conflict keeps furthest progress and merges flags`() {
        let local = ContentStateValues(
            watchProgress: 1200, isWatched: false, lastWatchedDate: Date(timeIntervalSince1970: 100),
            isFavorite: true, addedToWatchlistDate: Date(timeIntervalSince1970: 50), favoriteOrder: nil
        )
        let cloud = ContentStateValues(
            watchProgress: 600, isWatched: true, lastWatchedDate: Date(timeIntervalSince1970: 200),
            isFavorite: false, addedToWatchlistDate: Date(timeIntervalSince1970: 80), favoriteOrder: 3
        )
        let merged = ContentStateValues.mergeConflict(local: local, cloud: cloud)

        #expect(merged.watchProgress == 1200) // furthest
        #expect(merged.isWatched == true) // OR
        #expect(merged.isFavorite == true) // OR (never lose a favorite)
        #expect(merged.lastWatchedDate == Date(timeIntervalSince1970: 200)) // later
        #expect(merged.addedToWatchlistDate == Date(timeIntervalSince1970: 50)) // earliest add
        #expect(merged.favoriteOrder == 3) // local nil → cloud
    }

    @Test func `playlist conflict resolves last-write-wins favouring cloud`() {
        let local = PlaylistConfigValues(
            name: "Local", serverURL: "a", username: "u", password: "p",
            sourceTypeRaw: "xtream", epgURL: nil, syncEnabled: true
        )
        let cloud = PlaylistConfigValues(
            name: "Cloud", serverURL: "b", username: "u2", password: "p2",
            sourceTypeRaw: "xtream", epgURL: nil, syncEnabled: false
        )
        #expect(PlaylistConfigValues.mergeConflict(local: local, cloud: cloud) == cloud)
    }

    @Test func `empty content state is treated as absent`() {
        let empty = ContentStateValues(
            watchProgress: 0, isWatched: false, lastWatchedDate: nil,
            isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil
        )
        #expect(empty.isEmpty)
    }
}

// MARK: - Engine integration (in-memory, no CloudKit)

@MainActor
struct CloudSyncEngineTests {
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
        let suite = UserDefaults(suiteName: "cloudsync.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    @Test func `local playlist and favorite export to cloud mirrors`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        let pid = playlist.id
        ctx.insert(playlist)

        let movie = Movie(id: "\(pid.uuidString)-movie-1", streamId: 1, name: "Film")
        movie.isFavorite = true
        movie.watchProgress = 42
        ctx.insert(movie)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        #expect(result.playlistsPushed == 1)
        #expect(result.contentPushed == 1)

        let mirrors = try ctx.fetch(FetchDescriptor<SyncedPlaylist>())
        #expect(mirrors.count == 1)
        #expect(mirrors.first?.id == pid)
        #expect(mirrors.first?.password == "p")

        let states = try ctx.fetch(FetchDescriptor<UserContentState>())
        #expect(states.count == 1)
        #expect(states.first?.contentId == "\(pid.uuidString)-movie-1")
        #expect(states.first?.isFavorite == true)
        #expect(states.first?.watchProgress == 42)
    }

    @Test func `cloud playlist creates a local playlist`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let pid = UUID()
        ctx.insert(SyncedPlaylist(
            id: pid, name: "Remote", serverURL: "http://r", username: "ru", password: "rp",
            sourceTypeRaw: "xtream", epgURL: nil, syncEnabled: true
        ))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        #expect(result.playlistsCreatedLocally == 1)
        let locals = try ctx.fetch(FetchDescriptor<Playlist>())
        #expect(locals.count == 1)
        #expect(locals.first?.id == pid)
        #expect(locals.first?.name == "Remote")
        #expect(locals.first?.lastSyncDate == nil) // so auto-sync fetches its catalog
    }

    @Test func `cloud content state stays pending until its catalog item exists`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let shadow = freshShadow()
        let pid = UUID()
        let movieId = "\(pid.uuidString)-movie-7"

        ctx.insert(SyncedPlaylist(
            id: pid, name: "Remote", serverURL: "http://r", username: "u", password: "p",
            sourceTypeRaw: "xtream", epgURL: nil, syncEnabled: true
        ))
        ctx.insert(UserContentState(contentId: movieId, kind: .movie, isFavorite: true))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: shadow)

        // First pass: playlist created locally, but the movie isn't synced yet.
        let first = await engine.reconcile()
        #expect(first.contentPending == 1)
        #expect(try ctx.fetch(FetchDescriptor<Movie>()).isEmpty)

        // Catalog sync brings the movie in (favorite still off locally).
        ctx.insert(Movie(id: movieId, streamId: 7, name: "Pending Film"))
        try ctx.save()

        // Second pass: the pending favorite is applied.
        let second = await engine.reconcile()
        #expect(second.contentPulled == 1)

        let movie = try ctx.fetch(FetchDescriptor<Movie>()).first
        #expect(movie?.isFavorite == true)
    }

    @Test func `empty local catalog with a populated shadow never deletes cloud mirrors`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let shadow = freshShadow()

        // Seed a playlist + a favorite movie and reconcile once, so the cloud
        // mirrors exist and the shadow records a baseline for both.
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

        // Simulate the catastrophe: the local catalog comes up empty (a vanished
        // or recreated `default.store`) while the shadow and the CloudKit mirrors
        // still hold the data. A naive merge would read every absent local item
        // as a deletion and push it to the cloud, wiping every device.
        ctx.delete(playlist)
        ctx.delete(movie)
        try ctx.save()

        let result = await engine.reconcile()

        #expect(result.recoveredFromEmptyLocalStore)
        // The irreplaceable cloud copy must survive — no deletions pushed.
        #expect(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).count == 1)
        #expect(try ctx.fetch(FetchDescriptor<UserContentState>()).count == 1)
        // …and the device recovers: the cloud playlist is pulled back locally.
        let recovered = try ctx.fetch(FetchDescriptor<Playlist>())
        #expect(recovered.count == 1)
        #expect(recovered.first?.id == pid)
    }

    @Test func `empty local catalog with an empty shadow still pulls from the cloud`() async throws {
        // A genuinely fresh device (or a clean reinstall) has an empty shadow, so
        // the integrity gate must NOT block it — it has to pull cloud playlists in.
        let container = try makeContainer()
        let ctx = container.mainContext
        let pid = UUID()
        ctx.insert(SyncedPlaylist(
            id: pid, name: "Remote", serverURL: "http://r", username: "ru", password: "rp",
            sourceTypeRaw: "xtream", epgURL: nil, syncEnabled: true
        ))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        #expect(!result.skippedUntrustworthyLocalStore)
        #expect(result.playlistsCreatedLocally == 1)
    }

    @Test func `state whose playlist is gone is garbage-collected`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let pid = UUID() // no playlist (local or cloud) for this id
        ctx.insert(UserContentState(contentId: "\(pid.uuidString)-movie-1", kind: .movie, isFavorite: true))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await engine.reconcile()

        #expect(try ctx.fetch(FetchDescriptor<UserContentState>()).isEmpty)
    }

    // MARK: - EPG sources

    @Test func `manual EPG source exports to a cloud mirror`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let source = EPGSource(name: "Custom", url: "http://x/guide.xml")
        let sid = source.id
        ctx.insert(source)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        #expect(result.epgSourcesPushed == 1)
        let mirrors = try ctx.fetch(FetchDescriptor<SyncedEPGSource>())
        #expect(mirrors.count == 1)
        #expect(mirrors.first?.id == sid)
        #expect(mirrors.first?.url == "http://x/guide.xml")
    }

    @Test func `cloud EPG source creates a local manual source`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let sid = UUID()
        ctx.insert(SyncedEPGSource(id: sid, name: "Remote Guide", url: "http://r/epg.xml", isEnabled: true))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        #expect(result.epgSourcesPulled == 1)
        let locals = try ctx.fetch(FetchDescriptor<EPGSource>())
        #expect(locals.count == 1)
        #expect(locals.first?.id == sid)
        #expect(locals.first?.isManual == true)
        #expect(locals.first?.url == "http://r/epg.xml")
    }

    @Test func `a pulled playlist regenerates its linked EPG source locally`() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let pid = UUID()
        ctx.insert(SyncedPlaylist(
            id: pid, name: "Remote", serverURL: "http://host:8080", username: "u", password: "p",
            sourceTypeRaw: "xtream", epgURL: nil, syncEnabled: true
        ))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await engine.reconcile()

        let sources = try ctx.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.count == 1)
        let linked = try #require(sources.first)
        #expect(linked.playlistID == pid)
        #expect(linked.url.contains("xmltv.php"))

        // The derived source is local-only — it must not be mirrored to the cloud.
        #expect(try ctx.fetch(FetchDescriptor<SyncedEPGSource>()).isEmpty)
    }
}

// MARK: - Initial-sync launch gate

/// The launch gate (`status.hasCompletedInitialSync`) that a fresh install waits
/// on before showing the add-playlist form. The actual wait fires only when
/// CloudKit is enabled, which can't run in an un-entitled test binary (it
/// crashes — the very reason `cloudKitEnabled` exists), so this covers the
/// disabled path that previews, unit tests and UI tests take: the gate must be
/// open from the start so the form stays reachable on an empty store.
@MainActor
struct CloudSyncInitialGateTests {
    @Test func `gate is open from init when CloudKit is disabled`() throws {
        // The coordinator's engine only opens a ModelContext at init (it never
        // fetches) and the CloudKit-disabled path returns before touching the
        // cloud store, so the shared catalog container is enough here.
        let container = try makeTestContainer()
        let coordinator = CloudSyncCoordinator(
            catalogContainer: container,
            cloudContainer: container,
            cloudKitContainerIdentifier: "iCloud.test",
            cloudKitEnabled: false
        )
        #expect(coordinator.status.hasCompletedInitialSync)
    }
}

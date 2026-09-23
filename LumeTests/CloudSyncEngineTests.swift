//
//  CloudSyncEngineTests.swift
//  LumeTests
//
//  The iCloud-sync engine's end-to-end behaviour against an in-memory
//  two-configuration store (no CloudKit needed). Split from CloudSyncTests.swift
//  purely to keep that file under the line-length cap.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

private nonisolated enum InjectedReconcileSaveError: Error {
    case forced
}

// MARK: - Engine integration (in-memory, no CloudKit)

@MainActor
struct CloudSyncEngineTests {
    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "cloudsync.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    @Test func `local playlist and favorite export to cloud mirrors`() async throws {
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

    @Test func `failed reconcile restores its shadow so the next pass retries`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let shadow = freshShadow()
        let playlist = Playlist(
            name: "My IPTV",
            serverURL: "http://x",
            username: "u",
            password: "p"
        )
        let playlistID = playlist.id
        ctx.insert(playlist)
        try ctx.save()

        let failingEngine = CloudSyncEngine(
            container: container,
            shadow: shadow,
            saveFailureInjector: { role in
                if role == .catalog { throw InjectedReconcileSaveError.forced }
            }
        )
        let failed = await failingEngine.reconcile()

        #expect(failed.failed)
        #expect(shadow.playlistShadow(playlistID.uuidString) == nil)
        #expect(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).isEmpty)

        let retryingEngine = CloudSyncEngine(container: container, shadow: shadow)
        let retried = await retryingEngine.reconcile()

        #expect(!retried.failed)
        #expect(retried.playlistsPushed == 1)
        #expect(shadow.playlistShadow(playlistID.uuidString) != nil)
        #expect(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).count == 1)
    }

    @Test func `cloud playlist creates a local playlist`() async throws {
        let container = try makeProfileTestContainer()
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

    @Test func `cloud webdav playlist creates a local webdav playlist`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let pid = UUID()
        ctx.insert(SyncedPlaylist(
            id: pid, name: "NAS", serverURL: "http://nas.local/Movies/", username: "nu", password: "np",
            sourceTypeRaw: PlaylistSourceType.webdav.rawValue, epgURL: nil, syncEnabled: true
        ))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        #expect(result.playlistsCreatedLocally == 1)
        let local = try #require(try ctx.fetch(FetchDescriptor<Playlist>()).first)
        // The credentials have to survive the pull: a share that arrives
        // without them 401s on every PROPFIND and every playback open.
        #expect(local.sourceType == .webdav)
        #expect(local.serverURL == "http://nas.local/Movies/")
        #expect(local.username == "nu")
        #expect(local.password == "np")
    }

    /// A newer build can mirror a source type this one has never heard of.
    /// `Playlist.sourceType` resolves an unknown raw value through `?? .xtream`,
    /// so adopting the record would aim the Xtream pipeline at the user's own
    /// server with their credentials — and then push that wrong raw value back
    /// to CloudKit for every sibling device.
    @Test func `cloud playlist with an unknown source type is skipped, not adopted as xtream`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let shadow = freshShadow()

        // A known-good local playlist keeps the catalog non-empty, so the
        // integrity gate can't be what suppresses the pull.
        let existing = Playlist(name: "Mine", serverURL: "http://x", username: "u", password: "p")
        ctx.insert(existing)

        let pid = UUID()
        ctx.insert(SyncedPlaylist(
            id: pid, name: "From The Future", serverURL: "http://nas.local/Share/", username: "fu", password: "fp",
            sourceTypeRaw: "quantumdav", epgURL: nil, syncEnabled: true
        ))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: shadow)
        let result = await engine.reconcile()

        #expect(result.playlistsCreatedLocally == 0)
        let locals = try ctx.fetch(FetchDescriptor<Playlist>())
        #expect(locals.count == 1)
        #expect(locals.first?.id == existing.id)
        #expect(!locals.contains { $0.id == pid })

        // The shadow stays untouched, so the record is still "new" to a later
        // build that does understand the type — skipping must not baseline it.
        #expect(shadow.playlistShadow(pid.uuidString) == nil)

        // And the mirror is left exactly as it was: no rewrite to `xtream`.
        let mirror = try #require(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).first { $0.id == pid })
        #expect(mirror.sourceTypeRaw == "quantumdav")
    }

    @Test func `cloud content state stays pending until its catalog item exists`() async throws {
        let container = try makeProfileTestContainer()
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
        let container = try makeProfileTestContainer()
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
        let container = try makeProfileTestContainer()
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
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let pid = UUID() // no playlist (local or cloud) for this id
        ctx.insert(UserContentState(contentId: "\(pid.uuidString)-movie-1", kind: .movie, isFavorite: true))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await engine.reconcile()

        #expect(try ctx.fetch(FetchDescriptor<UserContentState>()).isEmpty)
    }

    // MARK: - Content Management (hidden categories / channels, category order)

    @Test func `a hidden category exports to a cloud mirror`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext

        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        ctx.insert(playlist)

        let category = Lume.Category(apiId: "12", name: "Sports", parentId: 0, type: .live, playlist: playlist)
        category.isHidden = true
        category.customOrder = 2
        ctx.insert(category)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        #expect(result.contentPushed == 1)
        let states = try ctx.fetch(FetchDescriptor<UserContentState>())
        let mirror = try #require(states.first { $0.kind == .category })
        #expect(mirror.contentId == category.id)
        #expect(mirror.isHidden == true)
        #expect(mirror.customOrder == 2)
    }

    @Test func `a cloud category state hides the matching local category`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext

        // The catalog already has the playlist + a visible category (as a fresh
        // device would after its first content sync).
        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        ctx.insert(playlist)
        let category = Lume.Category(apiId: "12", name: "Sports", parentId: 0, type: .live, playlist: playlist)
        ctx.insert(category)

        // The cloud mirror says it should be hidden and reordered.
        ctx.insert(UserContentState(contentId: category.id, kind: .category, isHidden: true, customOrder: 4))
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let result = await engine.reconcile()

        #expect(result.contentPulled == 1)
        let updated = try #require(try ctx.fetch(FetchDescriptor<Lume.Category>()).first)
        #expect(updated.isHidden == true)
        #expect(updated.customOrder == 4)
    }

    @Test func `a hidden channel syncs but its per-category order does not`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext

        let playlist = Playlist(name: "My IPTV", serverURL: "http://x", username: "u", password: "p")
        let pid = playlist.id
        ctx.insert(playlist)

        // Hidden channel → mirrored. A channel that's only reordered (customOrder
        // set, not hidden, not favorite) must NOT produce a mirror record.
        let hidden = LiveStream(id: "\(pid.uuidString)-live-1", streamId: 1, name: "Hidden")
        hidden.isHidden = true
        hidden.customOrder = 0
        ctx.insert(hidden)
        let reorderedOnly = LiveStream(id: "\(pid.uuidString)-live-2", streamId: 2, name: "Reordered")
        reorderedOnly.customOrder = 1
        ctx.insert(reorderedOnly)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await engine.reconcile()

        let states = try ctx.fetch(FetchDescriptor<UserContentState>())
        #expect(states.count == 1)
        let mirror = try #require(states.first)
        #expect(mirror.contentId == "\(pid.uuidString)-live-1")
        #expect(mirror.isHidden == true)
        #expect(mirror.customOrder == nil) // per-channel order stays device-local
    }

    // MARK: - EPG sources

    @Test func `manual EPG source exports to a cloud mirror`() async throws {
        let container = try makeProfileTestContainer()
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
        let container = try makeProfileTestContainer()
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
        let container = try makeProfileTestContainer()
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

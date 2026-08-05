import Foundation
@testable import Lume
import SwiftData
import Testing

struct EPGSourceReconcilerTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, EPGSource.self, Category.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - guideURL

    @Test func `guideURL for xtream playlist returns xmltv URL`() throws {
        let playlist = Playlist(name: "Test", serverURL: "http://example.com:8080", username: "user", password: "pass")
        let url = EPGSourceReconciler.guideURL(for: playlist)
        let urlString = try #require(url)
        #expect(urlString.contains("xmltv.php"))
        #expect(urlString.contains("username=user"))
        #expect(urlString.contains("password=pass"))
    }

    @Test func `guideURL for m3u playlist with epgURL returns it`() throws {
        let playlist = Playlist(name: "Test", m3uURL: "http://example.com/playlist.m3u", epgURL: "http://example.com/guide.xml")
        let url = EPGSourceReconciler.guideURL(for: playlist)
        #expect(url == "http://example.com/guide.xml")
    }

    @Test func `guideURL for m3u playlist without epgURL returns nil`() throws {
        let playlist = Playlist(name: "Test", m3uURL: "http://example.com/playlist.m3u")
        let url = EPGSourceReconciler.guideURL(for: playlist)
        #expect(url == nil)
    }

    @Test func `guideURL for stalker playlist without epgURL returns nil`() throws {
        let playlist = Playlist(name: "Test", portalURL: "http://portal.example.com", macAddress: "00:1A:79:12:34:56")
        let url = EPGSourceReconciler.guideURL(for: playlist)
        #expect(url == nil)
    }

    @Test func `guideURL for stalker playlist with epgURL returns it`() throws {
        let playlist = Playlist(name: "Test", portalURL: "http://portal.example.com", macAddress: "00:1A:79:12:34:56")
        playlist.epgURL = "http://example.com/stalker-guide.xml"
        let url = EPGSourceReconciler.guideURL(for: playlist)
        #expect(url == "http://example.com/stalker-guide.xml")
    }

    // MARK: - apply

    @Test func `apply creates source for xtream playlist`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test", serverURL: "http://example.com:8080", username: "user", password: "pass")
        context.insert(playlist)
        try context.save()

        let changed = EPGSourceReconciler.apply(playlist, in: context)
        #expect(changed)

        let sources = try context.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.count == 1)
        #expect(sources[0].name == "Test")
        #expect(sources[0].playlistID == playlist.id)
        #expect(sources[0].url.contains("xmltv.php"))
    }

    @Test func `apply creates source for m3u playlist with guide URL`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "M3U Test", m3uURL: "http://example.com/playlist.m3u", epgURL: "http://example.com/guide.xml")
        context.insert(playlist)
        try context.save()

        let changed = EPGSourceReconciler.apply(playlist, in: context)
        #expect(changed)

        let sources = try context.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.count == 1)
        #expect(sources[0].url == "http://example.com/guide.xml")
    }

    @Test func `apply does not create source for m3u without guide URL`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "No Guide", m3uURL: "http://example.com/playlist.m3u")
        context.insert(playlist)
        try context.save()

        let changed = EPGSourceReconciler.apply(playlist, in: context)
        #expect(!changed)

        let sources = try context.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.isEmpty)
    }

    @Test func `apply updates existing source when url changes`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test", serverURL: "http://example.com:8080", username: "user", password: "pass")
        context.insert(playlist)
        try context.save()

        _ = EPGSourceReconciler.apply(playlist, in: context)

        playlist.serverURL = "http://new.example.com:8080"
        let changed = EPGSourceReconciler.apply(playlist, in: context)
        #expect(changed)

        let sources = try context.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.count == 1)
        #expect(sources[0].url.contains("new.example.com"))
    }

    @Test func `apply updates existing source when name changes`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Old Name", serverURL: "http://example.com:8080", username: "user", password: "pass")
        context.insert(playlist)
        try context.save()

        _ = EPGSourceReconciler.apply(playlist, in: context)

        playlist.name = "New Name"
        let changed = EPGSourceReconciler.apply(playlist, in: context)
        #expect(changed)

        let sources = try context.fetch(FetchDescriptor<EPGSource>())
        #expect(sources[0].name == "New Name")
    }

    @Test func `apply is idempotent when nothing changes`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test", serverURL: "http://example.com:8080", username: "user", password: "pass")
        context.insert(playlist)
        try context.save()

        _ = EPGSourceReconciler.apply(playlist, in: context)
        let changed = EPGSourceReconciler.apply(playlist, in: context)
        #expect(!changed)

        let sources = try context.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.count == 1)
    }

    @Test func `apply removes source when guide url disappears`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test", m3uURL: "http://example.com/playlist.m3u", epgURL: "http://example.com/guide.xml")
        context.insert(playlist)
        try context.save()

        _ = EPGSourceReconciler.apply(playlist, in: context)

        playlist.epgURL = nil
        let changed = EPGSourceReconciler.apply(playlist, in: context)
        #expect(changed)

        let sources = try context.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.isEmpty)
    }

    // MARK: - reconcile

    @Test func `reconcile saves changes`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test", serverURL: "http://example.com:8080", username: "user", password: "pass")
        context.insert(playlist)
        try context.save()

        EPGSourceReconciler.reconcile(playlist, in: context)

        let sources = try context.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.count == 1)
    }

    // MARK: - remove

    @Test func `remove deletes linked source`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test", serverURL: "http://example.com:8080", username: "user", password: "pass")
        context.insert(playlist)
        try context.save()

        EPGSourceReconciler.reconcile(playlist, in: context)

        EPGSourceReconciler.remove(playlistID: playlist.id, in: context)

        let sources = try context.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.isEmpty)
    }

    @Test func `remove for non existent source does nothing`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        EPGSourceReconciler.remove(playlistID: UUID(), in: context)
        let sources = try context.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.isEmpty)
    }

    // MARK: - linkedSourcesByPlaylist

    @Test func `linkedSourcesByPlaylist returns mapping`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let p1 = Playlist(name: "P1", serverURL: "http://a.com:8080", username: "u", password: "p")
        let p2 = Playlist(name: "P2", m3uURL: "http://b.com/playlist.m3u", epgURL: "http://b.com/guide.xml")
        context.insert(p1)
        context.insert(p2)
        try context.save()

        EPGSourceReconciler.reconcile(p1, in: context)
        EPGSourceReconciler.reconcile(p2, in: context)

        let byPlaylist = EPGSourceReconciler.linkedSourcesByPlaylist(in: context)
        #expect(byPlaylist.count == 2)
    }

    @Test func `linkedSourcesByPlaylist includes manual sources`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let manual = EPGSource(name: "Manual", url: "http://example.com/manual.xml", playlistID: nil)
        context.insert(manual)
        try context.save()

        let byPlaylist = EPGSourceReconciler.linkedSourcesByPlaylist(in: context)
        #expect(byPlaylist.isEmpty)
    }
}

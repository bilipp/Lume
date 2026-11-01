//
//  IntentCatalogResolverTests.swift
//  LumeTests
//
//  The Siri catalog lookup: visibility (restricted and hidden categories,
//  hidden channels, playlists the free plan locks), ranking, tie detection and
//  the provider-prefix stripping of spoken titles. Runs on an on-disk SQLite
//  store, where the search predicates' SQL is actually generated.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct IntentCatalogResolverTests {
    private struct Catalog {
        let container: ModelContainer
        let first: Playlist
        let second: Playlist
    }

    /// Two playlists, `first` added before `second` — so `first` is the one the
    /// free plan keeps.
    private func makeCatalog() throws -> Catalog {
        let schema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext
        let first = Playlist(name: "Home", serverURL: "http://a.example", username: "u", password: "p")
        first.addedAt = Date(timeIntervalSince1970: 1000)
        let second = Playlist(name: "Travel", serverURL: "http://b.example", username: "u", password: "p")
        second.addedAt = Date(timeIntervalSince1970: 2000)
        context.insert(first)
        context.insert(second)
        try context.save()
        return Catalog(container: container, first: first, second: second)
    }

    @discardableResult
    private func channel(
        _ name: String,
        in playlist: Playlist,
        id: String,
        category: String? = nil,
        context: ModelContext
    ) -> LiveStream {
        let stream = LiveStream(id: "\(playlist.id.uuidString)-live-\(id)", streamId: 1, name: name, categoryId: category)
        context.insert(stream)
        return stream
    }

    private func resolver(
        _ catalog: Catalog,
        restriction: ContentRestriction = ContentRestriction(),
        isPremium: Bool = true,
        active: Playlist? = nil
    ) -> IntentCatalogResolver {
        let context = ModelContext(catalog.container)
        let playlists = ((try? context.fetch(FetchDescriptor<Playlist>())) ?? []).unlocked(isPremium: isPremium)
        return IntentCatalogResolver(
            context: context,
            playlists: playlists,
            restriction: restriction,
            activePlaylistID: (active ?? catalog.first).id.uuidString
        )
    }

    // MARK: - Visibility

    @Test func `restricted category never matches for a child profile`() throws {
        let catalog = try makeCatalog()
        let context = catalog.container.mainContext
        let movie = Movie(id: "\(catalog.first.id.uuidString)-movie-1", streamId: 1, name: "Saw", categoryId: "adult")
        context.insert(movie)
        try context.save()

        let child = ContentRestriction(isActive: true, restrictedCategoryIDs: ["adult"])
        #expect(resolver(catalog, restriction: child).search(kind: .movie, name: "Saw", limit: 5).items.isEmpty)

        movie.isFavorite = true
        try context.save()
        #expect(resolver(catalog, restriction: child).suggested(kind: .movie, limit: 5).isEmpty)

        let parent = ContentRestriction(isActive: false, restrictedCategoryIDs: ["adult"])
        #expect(resolver(catalog, restriction: parent).search(kind: .movie, name: "Saw", limit: 5).items.count == 1)
    }

    @Test func `hidden channel and hidden category never match`() throws {
        let catalog = try makeCatalog()
        let context = catalog.container.mainContext
        let hidden = channel("Arte", in: catalog.first, id: "1", context: context)
        hidden.isHidden = true
        hidden.isFavorite = true
        channel("Arte HD", in: catalog.first, id: "2", category: "fr", context: context)
        try context.save()

        let restriction = ContentRestriction(hiddenCategoryIDs: ["fr"])
        let resolver = resolver(catalog, restriction: restriction)
        #expect(resolver.search(kind: .channel, name: "Arte", limit: 5).items.isEmpty)
        #expect(resolver.suggested(kind: .channel, limit: 5).isEmpty)
    }

    @Test func `pro locked playlist is never searched`() throws {
        let catalog = try makeCatalog()
        let context = catalog.container.mainContext
        channel("CNN", in: catalog.first, id: "1", context: context)
        let locked = channel("CNN International", in: catalog.second, id: "2", context: context)
        locked.isFavorite = true
        try context.save()

        let free = resolver(catalog, isPremium: false)
        #expect(free.search(kind: .channel, name: "CNN", limit: 5).items.map(\.playlistName) == ["Home"])
        #expect(free.suggested(kind: .channel, limit: 5).isEmpty)

        let pro = resolver(catalog, isPremium: true)
        #expect(pro.search(kind: .channel, name: "CNN", limit: 5).items.count == 2)
    }

    // MARK: - Ranking

    @Test func `duplicate names across playlists tie and are told apart by playlist`() throws {
        let catalog = try makeCatalog()
        let context = catalog.container.mainContext
        let third = Playlist(name: "Spare", serverURL: "http://c.example", username: "u", password: "p")
        third.addedAt = Date(timeIntervalSince1970: 3000)
        context.insert(third)
        channel("DE | ZDF", in: catalog.second, id: "1", context: context)
        channel("ZDF", in: third, id: "1", context: context)
        try context.save()

        let matches = resolver(catalog).search(kind: .channel, name: "zdf", limit: 5)
        #expect(matches.isAmbiguous)
        #expect(matches.items.map(\.displayTitle) == ["ZDF", "ZDF"])
        #expect(Set(matches.items.map(\.playlistName)) == ["Travel", "Spare"])
    }

    @Test func `an exact match breaks a tie`() throws {
        let catalog = try makeCatalog()
        let context = catalog.container.mainContext
        channel("Das Erste HD", in: catalog.first, id: "1", context: context)
        channel("UK: Das Érste", in: catalog.first, id: "2", context: context)
        try context.save()

        let matches = resolver(catalog).search(kind: .channel, name: "das erste", limit: 5)
        #expect(!matches.isAmbiguous)
        #expect(matches.items.first?.id == "\(catalog.first.id.uuidString)-live-2")
    }

    @Test func `favorites and recents rank before active playlist before exact match`() throws {
        let catalog = try makeCatalog()
        let context = catalog.container.mainContext
        let prefix = catalog.first.id.uuidString
        let otherPrefix = catalog.second.id.uuidString
        let exactElsewhere = Series(id: "\(otherPrefix)-series-1", seriesId: 1, name: "Dark")
        let active = Series(id: "\(prefix)-series-2", seriesId: 2, name: "Dark Matter")
        let recent = Series(id: "\(otherPrefix)-series-3", seriesId: 3, name: "Dark Angel")
        recent.lastWatchedDate = Date()
        let favorite = Series(id: "\(otherPrefix)-series-4", seriesId: 4, name: "Dark Shadows")
        favorite.isFavorite = true
        for series in [exactElsewhere, active, recent, favorite] {
            context.insert(series)
        }
        try context.save()

        let matches = resolver(catalog, active: catalog.first).search(kind: .series, name: "Dark", limit: 10)
        #expect(matches.items.map(\.id) == [recent.id, favorite.id, active.id, exactElsewhere.id])
        #expect(!matches.isAmbiguous)

        let suggested = resolver(catalog).suggested(kind: .series, limit: 10)
        #expect(suggested.map(\.id) == [recent.id, favorite.id])
    }

    @Test func `search respects the limit and an empty name matches nothing`() throws {
        let catalog = try makeCatalog()
        let context = catalog.container.mainContext
        for index in 0 ..< 4 {
            channel("Sport \(index)", in: catalog.first, id: "\(index)", context: context)
        }
        try context.save()

        let resolver = resolver(catalog)
        #expect(resolver.search(kind: .channel, name: "sport", limit: 2).items.count == 2)
        #expect(resolver.search(kind: .channel, name: "  ", limit: 2).items.isEmpty)
        #expect(resolver.search(kind: .movie, name: "sport", limit: 2).items.isEmpty)
    }

    // MARK: - Display titles

    @Test(arguments: [
        ("DE | Das Erste HD", "Das Erste HD"),
        ("UK: BBC One", "BBC One"),
        ("[DE] ZDF", "ZDF"),
        ("|UK| Sky News", "Sky News"),
        ("(FR) TF1", "TF1"),
        ("USA - CNN", "CNN"),
        ("4K | [DE] Sky Cinema", "Sky Cinema"),
        ("CSI: Miami", "CSI: Miami"),
        ("(500) Days of Summer", "(500) Days of Summer"),
        ("Love | Death", "Love | Death"),
        ("DE |", "DE |"),
        ("  Arte  ", "Arte")
    ])
    func `provider prefixes are stripped from display titles`(input: String, expected: String) {
        #expect(IntentCatalogResolver.displayTitle(input) == expected)
    }

    @Test func `normalization ignores case diacritics and spacing`() {
        #expect(IntentCatalogResolver.normalized("  Das   ÉRSTE ") == IntentCatalogResolver.normalized("das erste"))
    }
}

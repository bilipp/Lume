//
//  LiveChannelProbeScopeTests.swift
//  LumeTests
//
//  The Live TV rail's existence probes under a `CatalogScope`, on a real store
//  file: an in-memory store evaluates predicates in Swift, so a composed
//  `evaluate()` SQLite cannot be handed would pass there and trap on device.
//
//  An isolated scope must keep the probe isolated mode always had — inline
//  `id.starts(with:)`, no `evaluate` node.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct LiveChannelProbeScopeTests {
    private let first = UUID()
    private let second = UUID()
    private let moviesOnly = UUID()
    private let outsider = UUID()

    private var combined: CatalogScope {
        .combined([
            (id: first, tabs: [.liveTV]),
            (id: second, tabs: [.liveTV, .movies]),
            (id: moviesOnly, tabs: [.movies])
        ])
    }

    private func insertFavorite(
        _ playlist: UUID, _ suffix: String, category: String? = nil, in context: ModelContext
    ) throws {
        let stream = LiveStream(
            id: "\(playlist.uuidString)-live-\(suffix)", streamId: 1, name: "Channel \(suffix)", categoryId: category
        )
        stream.isFavorite = true
        stream.lastWatchedDate = Date()
        context.insert(stream)
        try context.save()
    }

    @Test func `an isolated probe keeps the inline prefix predicate`() throws {
        let prefix = "\(first.uuidString)-"
        let excluded: Set<String?> = []
        let filtersCategories = false
        let today = #Predicate<LiveStream> { stream in
            stream.isFavorite && stream.isHidden == false && stream.id.starts(with: prefix)
                && (!filtersCategories || stream.categoryId == nil || !excluded.contains(stream.categoryId))
        }

        let probe = LiveChannelQuery.favoritesProbe(catalogScope: .isolated(first), restriction: ContentRestriction())
        let built = try #require(probe.predicate)
        #expect(String(describing: type(of: built.expression)) == String(describing: type(of: today.expression)))
        #expect(!String(describing: type(of: built.expression)).contains("Evaluate"))
    }

    @Test func `combined probes stay limit-one with no sort`() {
        for descriptor in [
            LiveChannelQuery.favoritesProbe(catalogScope: combined, restriction: ContentRestriction()),
            LiveChannelQuery.recentlyWatchedProbe(catalogScope: combined, restriction: ContentRestriction())
        ] {
            #expect(descriptor.fetchLimit == 1)
            #expect(descriptor.sortBy.isEmpty)
        }
    }

    @Test func `combined probes see every live member and nothing else`() throws {
        try OnDiskCatalogStore.withContext { context in
            // Neither the outsider nor a member that contributes no Live TV
            // may light up the rail.
            try insertFavorite(outsider, "1", in: context)
            try insertFavorite(moviesOnly, "1", in: context)
            let restriction = ContentRestriction()
            #expect(try context.fetch(LiveChannelQuery.favoritesProbe(catalogScope: combined, restriction: restriction)).isEmpty)
            #expect(try context.fetch(LiveChannelQuery.recentlyWatchedProbe(catalogScope: combined, restriction: restriction)).isEmpty)

            try insertFavorite(second, "1", in: context)
            let favorites = try context.fetch(LiveChannelQuery.favoritesProbe(catalogScope: combined, restriction: restriction))
            let recents = try context.fetch(LiveChannelQuery.recentlyWatchedProbe(catalogScope: combined, restriction: restriction))
            #expect(favorites.map(\.id) == ["\(second.uuidString)-live-1"])
            #expect(recents.map(\.id) == ["\(second.uuidString)-live-1"])
        }
    }

    @Test func `a combined probe applies the restriction in SQL`() throws {
        try OnDiskCatalogStore.withContext { context in
            let locked = "\(first.uuidString)-live-locked"
            try insertFavorite(first, "1", category: locked, in: context)

            let child = ContentRestriction(isActive: true, restrictedCategoryIDs: [locked])
            #expect(try context.fetch(LiveChannelQuery.favoritesProbe(catalogScope: combined, restriction: child)).isEmpty)
            let parent = ContentRestriction()
            #expect(try context.fetch(LiveChannelQuery.favoritesProbe(catalogScope: combined, restriction: parent)).count == 1)
        }
    }

    @Test func `the empty scope probes find nothing`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertFavorite(first, "1", in: context)
            let restriction = ContentRestriction()
            #expect(try context.fetch(LiveChannelQuery.favoritesProbe(catalogScope: .empty, restriction: restriction)).isEmpty)
            #expect(try context.fetch(LiveChannelQuery.recentlyWatchedProbe(catalogScope: .empty, restriction: restriction)).isEmpty)
        }
    }
}

//
//  LiveChannelNavigatorScopeTests.swift
//  LumeTests
//
//  The channel ring's descriptor and the Recently Watched reset under a
//  `CatalogScope`. On disk: an in-memory store evaluates predicates in Swift,
//  so a composed `evaluate()` CoreData cannot render as SQL would pass there
//  and trap on device.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct LiveChannelNavigatorScopeTests {
    private let first = UUID()
    private let second = UUID()
    private let outsider = UUID()

    private var combined: CatalogScope {
        .combined([(id: first, tabs: [.liveTV]), (id: second, tabs: [.liveTV, .movies])])
    }

    /// Three favorites per playlist, each playlist in its own category. The
    /// outsider's channels sort first, so a scope that leaks heads the ring.
    private func insertFavorites(in context: ModelContext) throws {
        for (rank, playlist) in [outsider, first, second].enumerated() {
            for index in 0 ..< 3 {
                let stream = LiveStream(
                    id: "\(playlist.uuidString)-live-\(index)",
                    streamId: index,
                    name: "Channel \(rank)-\(index)",
                    num: rank * 10 + index,
                    categoryId: "\(playlist.uuidString)-cat"
                )
                stream.isFavorite = true
                stream.lastWatchedDate = Date(timeIntervalSince1970: Double(1_700_000_000 + rank * 10 + index))
                context.insert(stream)
            }
        }
        try context.save()
    }

    private func descriptor(_ scope: LiveChannelScope, _ catalogScope: CatalogScope) -> FetchDescriptor<LiveStream> {
        LiveChannelNavigator.scopeDescriptor(
            scope: scope,
            sort: .playlist,
            catalogScope: catalogScope,
            restriction: ContentRestriction(),
            admittingHidden: nil
        )
    }

    private func expressionType(_ descriptor: FetchDescriptor<LiveStream>) throws -> String {
        try String(describing: type(of: #require(descriptor.predicate).expression))
    }

    // MARK: - Isolated mode is unchanged

    @Test func `an isolated ring keeps the plain prefix predicate`() throws {
        for scope in [LiveChannelScope.favorites, .recentlyWatched, .category("\(first.uuidString)-cat")] {
            #expect(try !expressionType(descriptor(scope, .isolated(first))).contains("Evaluate"))
        }
    }

    @Test func `an isolated ring walks only its own playlist`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertFavorites(in: context)
            let rows = try context.fetch(descriptor(.favorites, .isolated(first)))
            #expect(rows.map(\.id) == (0 ..< 3).map { "\(first.uuidString)-live-\($0)" })
        }
    }

    // MARK: - Combined stays in SQL

    @Test func `a combined favorites ring spans every member`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertFavorites(in: context)
            let scope = descriptor(.favorites, combined)
            #expect(try expressionType(scope).contains("Evaluate"))

            let expected = [first, second].flatMap { playlist in
                (0 ..< 3).map { "\(playlist.uuidString)-live-\($0)" }
            }
            #expect(try context.fetch(scope).map(\.id) == expected)
            #expect(try context.fetchCount(scope) == 6)

            let position = LiveChannelNavigator.positionDescriptor(scope, at: 3)
            #expect(try context.fetch(position).map(\.id) == ["\(second.uuidString)-live-0"])
        }
    }

    @Test func `a combined category ring stays in the category`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertFavorites(in: context)
            let rows = try context.fetch(descriptor(.category("\(second.uuidString)-cat"), combined))
            #expect(rows.map(\.id) == (0 ..< 3).map { "\(second.uuidString)-live-\($0)" })
        }
    }

    @Test func `a scope with no Live TV member walks nothing`() throws {
        try OnDiskCatalogStore.withContext { context in
            try insertFavorites(in: context)
            let moviesOnly = CatalogScope.combined([(id: first, tabs: [.movies]), (id: second, tabs: [.movies])])
            #expect(try context.fetchCount(descriptor(.favorites, moviesOnly)) == 0)
            #expect(try context.fetchCount(descriptor(.favorites, .empty)) == 0)
        }
    }

    // MARK: - Clearing Recently Watched

    @Test func `clearing Recently Watched clears every member and nothing else`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        try insertFavorites(in: context)

        await StorageManager.clearRecentlyWatchedChannels(catalogScope: combined, container: container)

        let watched = try ModelContext(container).fetch(FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.lastWatchedDate != nil }
        ))
        #expect(Set(watched.map(\.id)) == Set((0 ..< 3).map { "\(outsider.uuidString)-live-\($0)" }))
    }
}

//
//  ContentIndexerHiddenTests.swift
//  LumeTests
//
//  Titles in hidden categories are never indexed: the pending predicates skip
//  them and progress counts exclude them from both sides, so a pass still
//  completes. The predicates must run against an on-disk SQLite store: an
//  in-memory store evaluates them in Swift without SQL generation, so a form
//  CoreData can't render passes there and traps on device.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct ContentIndexerHiddenTests {
    private func seed(_ context: ModelContext) throws -> Set<String> {
        let hiddenVOD = Category(apiId: "nl", name: "NL", parentId: 0, typeRaw: "vod")
        hiddenVOD.isHidden = true
        let visibleVOD = Category(apiId: "en", name: "EN", parentId: 0, typeRaw: "vod")
        let hiddenSeries = Category(apiId: "nl", name: "NL", parentId: 0, typeRaw: "series")
        hiddenSeries.isHidden = true
        let visibleSeries = Category(apiId: "en", name: "EN", parentId: 0, typeRaw: "series")
        for category in [hiddenVOD, visibleVOD, hiddenSeries, visibleSeries] {
            context.insert(category)
        }

        let hiddenMovie = Movie(id: "m-hidden", streamId: 1, name: "Hidden Film")
        hiddenMovie.categoryId = hiddenVOD.id
        let visibleMovie = Movie(id: "m-visible", streamId: 2, name: "Visible Film")
        visibleMovie.categoryId = visibleVOD.id
        let orphan = Movie(id: "m-orphan", streamId: 3, name: "Orphan Film")
        for movie in [hiddenMovie, visibleMovie, orphan] {
            context.insert(movie)
        }

        let hiddenShow = Series(id: "s-hidden", seriesId: 1, name: "Hidden Show")
        hiddenShow.categoryId = hiddenSeries.id
        let visibleShow = Series(id: "s-visible", seriesId: 2, name: "Visible Show")
        visibleShow.categoryId = visibleSeries.id
        for show in [hiddenShow, visibleShow] {
            context.insert(show)
        }

        try context.save()
        return [hiddenVOD.id, hiddenSeries.id]
    }

    @Test func `hiddenCategoryIDs returns only hidden ids`() throws {
        try OnDiskCatalogStore.withContext { context in
            let hidden = try seed(context)
            #expect(try ContentIndexer.hiddenCategoryIDs(in: context) == hidden)
        }
    }

    @Test func `pending movies skip hidden categories but keep visible and uncategorised`() throws {
        try OnDiskCatalogStore.withContext { context in
            let hidden = try seed(context)
            let fetched = try context.fetch(
                FetchDescriptor<Movie>(predicate: ContentIndexer.pendingMoviePredicate(excluding: hidden))
            )
            #expect(Set(fetched.map(\.id)) == ["m-visible", "m-orphan"])
        }
    }

    @Test func `pending series skip hidden categories`() throws {
        try OnDiskCatalogStore.withContext { context in
            let hidden = try seed(context)
            let fetched = try context.fetch(
                FetchDescriptor<Series>(predicate: ContentIndexer.pendingSeriesPredicate(excluding: hidden))
            )
            #expect(fetched.map(\.id) == ["s-visible"])
        }
    }

    @Test func `visible and indexed counts exclude hidden titles`() throws {
        try OnDiskCatalogStore.withContext { context in
            let hidden = try seed(context)
            for id in ["m-visible", "m-hidden"] {
                var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                try #require(try context.fetch(descriptor).first).indexedAt = Date()
            }
            try context.save()

            let total = try context.fetchCount(
                FetchDescriptor<Movie>(predicate: ContentIndexer.visibleMoviePredicate(excluding: hidden))
            )
            let indexed = try context.fetchCount(
                FetchDescriptor<Movie>(predicate: ContentIndexer.indexedMoviePredicate(excluding: hidden))
            )
            #expect(total == 2)
            #expect(indexed == 1)
        }
    }

    @Test func `empty exclusion indexes everything`() throws {
        try OnDiskCatalogStore.withContext { context in
            _ = try seed(context)
            let movies = try context.fetch(
                FetchDescriptor<Movie>(predicate: ContentIndexer.pendingMoviePredicate(excluding: []))
            )
            let series = try context.fetch(
                FetchDescriptor<Series>(predicate: ContentIndexer.pendingSeriesPredicate(excluding: []))
            )
            #expect(Set(movies.map(\.id)) == ["m-hidden", "m-visible", "m-orphan"])
            #expect(Set(series.map(\.id)) == ["s-hidden", "s-visible"])
        }
    }
}

//
//  SportarrVisibilityTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SportarrVisibilityTests {
    @Test func `browse relocation preserves search and continuation visibility`() {
        let items = [VisibilityItem(id: "sport", categoryId: "open"), VisibilityItem(id: "film", categoryId: "open"), VisibilityItem(id: "locked", categoryId: "locked")]
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["locked"], browseExcludedContentIDs: ["sport"])
        #expect(items.excludingBrowseHidden(restriction).map(\.id) == ["film"])
        #expect(items.excludingRestricted(restriction).map(\.id) == ["sport", "film"])
        #expect(!restriction.hides(categoryID: "open"))
        let restored = ContentRestriction(isActive: true, restrictedCategoryIDs: ["locked"])
        #expect(items.excludingBrowseHidden(restored).map(\.id) == ["sport", "film"])
        #expect(restored.visibilityToken != restriction.visibilityToken)
    }

    @Test func `movie paging and indexing exclude sports inside SQLite`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        for number in 0 ..< 6 {
            let movie = Movie(id: "movie-\(number)", streamId: number, name: "Replay \(number)")
            movie.categoryId = "mixed"
            movie.isCategoryGroupPrimary = true
            context.insert(movie)
        }
        try context.save()
        let sports: Set = ["movie-0", "movie-1", "movie-2"]
        var page = CategoryGridQuery.movies(categoryId: "mixed", grouped: true, sortBy: [SortDescriptor(\.id)], excludingSports: sports)
        page.fetchLimit = 2
        #expect(try context.fetch(page).map(\.id) == ["movie-3", "movie-4"])
        page.fetchOffset = 2
        #expect(try context.fetch(page).map(\.id) == ["movie-5"])
        let pending = ContentIndexer.pendingMoviePredicate(excluding: [], excludingSports: sports)
        #expect(try context.fetchCount(FetchDescriptor(predicate: pending)) == 3)
        // The catalog remains intact. Search's established category-only path
        // and the continuation rail can still read every original item.
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 6)
    }

    @Test func `series relocation does not hide another show in the same category`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        for number in 0 ..< 2 {
            let series = Series(id: "series-\(number)", seriesId: number, name: "Show \(number)")
            series.categoryId = "mixed"
            context.insert(series)
        }
        try context.save()
        let descriptor = CategoryGridQuery.series(categoryId: "mixed", grouped: false, excludingSports: ["series-0"])
        #expect(try context.fetch(descriptor).map(\.id) == ["series-1"])
    }
}

private struct VisibilityItem: CategorizedContent, Identifiable {
    let id: String
    let categoryId: String?
}

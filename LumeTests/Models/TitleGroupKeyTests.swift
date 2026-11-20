//
//  TitleGroupKeyTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct TitleGroupKeyTests {
    @Test func `tmdb id takes precedence over the title`() {
        #expect(TitleGroupKey.movie(tmdbId: 238, name: "DE | Der Pate (1972) 4K") == "tmdb:238")
        #expect(TitleGroupKey.series(tmdbId: 1396, name: "Breaking Bad") == "tmdb:1396")
        #expect(TitleGroupKey.movie(tmdbId: 238, name: "") == "tmdb:238")
    }

    @Test func `a tmdb key names its id and a title key none`() {
        #expect(TitleGroupKey.tmdbId(groupKey: "tmdb:603") == 603)
        #expect(TitleGroupKey.tmdbId(groupKey: "t:the matrix|1999") == nil)
        #expect(TitleGroupKey.tmdbId(groupKey: nil) == nil)
    }

    @Test func `provider prefixes and quality tags are stripped`() {
        let expected = "t:der pate|1972"
        #expect(TitleGroupKey.movie(tmdbId: nil, name: "DE | Der Pate (1972) 4K") == expected)
        #expect(TitleGroupKey.movie(tmdbId: nil, name: "Der Pate 1972 FHD") == expected)
        #expect(TitleGroupKey.movie(tmdbId: nil, name: "[MULTI] Der Pate (1972) HDR") == expected)
        #expect(TitleGroupKey.movie(tmdbId: nil, name: "EN - Der Pate (1972)") == expected)
    }

    @Test func `case diacritics and punctuation fold`() {
        #expect(
            TitleGroupKey.movie(tmdbId: nil, name: "Amélie: Part 1 (2001)")
                == TitleGroupKey.movie(tmdbId: nil, name: "amelie - part 1 2001")
        )
    }

    @Test func `different years stay apart and a missing year is empty`() {
        #expect(TitleGroupKey.movie(tmdbId: nil, name: "Dune (1984)") == "t:dune|1984")
        #expect(TitleGroupKey.movie(tmdbId: nil, name: "Dune (2021)") == "t:dune|2021")
        #expect(TitleGroupKey.series(tmdbId: nil, name: "UK: Sherlock HD") == "t:sherlock|")
    }

    @Test func `a title that normalizes to empty is never grouped`() {
        #expect(TitleGroupKey.movie(tmdbId: nil, name: "") == nil)
        #expect(TitleGroupKey.series(tmdbId: nil, name: " - | ") == nil)
    }
}

/// The new columns and their predicates must work against an on-disk store,
/// where predicates go through SQL generation.
@MainActor
struct TitleGroupColumnTests {
    private func makeSQLiteContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func `new rows default to primary with no key`() {
        let movie = Movie(id: "m", streamId: 1, name: "Movie")
        let series = Series(id: "s", seriesId: 1, name: "Series")
        #expect(movie.titleGroupKey == nil && movie.isCategoryGroupPrimary)
        #expect(series.titleGroupKey == nil && series.isCategoryGroupPrimary)
    }

    @Test func `category grid predicate keeps only primaries`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        for (index, primary) in [true, false, true].enumerated() {
            let movie = Movie(id: "m\(index)", streamId: index, name: "Movie \(index)", categoryId: "c1")
            movie.titleGroupKey = "tmdb:\(index == 2 ? 2 : 1)"
            movie.isCategoryGroupPrimary = primary
            context.insert(movie)
        }
        let series = Series(id: "s1", seriesId: 1, name: "Series")
        series.categoryId = "c1"
        series.titleGroupKey = "tmdb:1"
        series.isCategoryGroupPrimary = false
        context.insert(series)
        try context.save()

        let categoryId = "c1"
        let movies = try context.fetch(FetchDescriptor<Movie>(
            predicate: #Predicate { $0.categoryId == categoryId && $0.isCategoryGroupPrimary },
            sortBy: [SortDescriptor(\.id)]
        ))
        #expect(movies.map(\.id) == ["m0", "m2"])

        let key = "tmdb:1"
        let siblings = try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.titleGroupKey == key }))
        #expect(siblings.count == 2)
        let primarySeries = try context.fetch(FetchDescriptor<Series>(
            predicate: #Predicate { $0.categoryId == categoryId && $0.isCategoryGroupPrimary }
        ))
        #expect(primarySeries.isEmpty)
    }
}

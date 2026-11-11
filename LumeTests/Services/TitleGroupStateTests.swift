//
//  TitleGroupStateTests.swift
//  LumeTests
//
//  Grouped cards show a title's state if any copy has it, and switching state
//  off clears every copy.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct TitleGroupStateTests {
    private static let first = UUID()
    private static let second = UUID()

    private func movie(
        _ suffix: String,
        _ name: String,
        playlist: UUID = first,
        tmdbId: Int? = nil,
        in context: ModelContext
    ) -> Movie {
        let movie = Movie(id: "\(playlist.uuidString)-movie-\(suffix)", streamId: 0, name: name)
        movie.tmdbId = tmdbId
        movie.titleGroupKey = TitleGroupKey.movie(tmdbId: tmdbId, name: name)
        context.insert(movie)
        return movie
    }

    private func series(_ suffix: String, _ name: String, playlist: UUID = first, in context: ModelContext) -> Series {
        let series = Series(id: "\(playlist.uuidString)-series-\(suffix)", seriesId: 0, name: name)
        series.titleGroupKey = TitleGroupKey.series(tmdbId: nil, name: name)
        context.insert(series)
        return series
    }

    // MARK: Aggregation

    @Test func `any copy's state shows on the title`() throws {
        try OnDiskCatalogStore.withContext { context in
            let uhd = movie("1", "Inception (2010) 4K", in: context)
            let fhd = movie("2", "Inception (2010) FHD", playlist: Self.second, in: context)
            let standard = movie("3", "Inception (2010) SD", in: context)
            let other = movie("4", "Heat (1995)", in: context)
            fhd.isFavorite = true
            standard.isWatched = true
            uhd.addedToWatchlistDate = Date()
            try context.save()

            let key = try #require(uhd.titleGroupKey)
            let otherKey = try #require(other.titleGroupKey)
            let states = TitleGroupStateLookup.movies(keys: [key, otherKey], in: context)

            #expect(states[key] == TitleGroupState(isFavorite: true, isWatched: true, isOnWatchlist: true))
            #expect(states[otherKey] == nil, "A title without state is left out")
            #expect(TitleGroupStateLookup.state(of: other, in: states) == .empty)
            #expect(TitleGroupStateLookup.state(of: uhd, in: states).isFavorite)
        }
    }

    @Test func `progress comes from the most recently watched copy`() throws {
        try OnDiskCatalogStore.withContext { context in
            let older = movie("1", "Inception (2010) 4K", in: context)
            let newer = movie("2", "Inception (2010) FHD", playlist: Self.second, in: context)
            let undated = movie("3", "Inception (2010) SD", in: context)
            older.watchProgress = 600
            older.lastWatchedDate = Date(timeIntervalSince1970: 1000)
            newer.watchProgress = 1200
            newer.lastWatchedDate = Date(timeIntervalSince1970: 2000)
            undated.watchProgress = 30
            try context.save()

            let key = try #require(older.titleGroupKey)
            let lastWatched = TitleGroupStateLookup.movies(keys: [key], in: context)[key]?.lastWatched
            #expect(lastWatched?.rowID == newer.id)
            #expect(lastWatched?.watchProgress == 1200)
        }
    }

    @Test func `rows without a key show only their own state`() throws {
        try OnDiskCatalogStore.withContext { context in
            let blankA = movie("1", " - ", in: context)
            let blankB = movie("2", " - ", in: context)
            blankB.isFavorite = true
            try context.save()

            #expect(blankA.titleGroupKey == nil)
            let states = TitleGroupStateLookup.movies(keys: [], in: context)
            #expect(TitleGroupStateLookup.state(of: blankA, in: states) == .empty)
            #expect(TitleGroupStateLookup.state(of: blankB, in: states).isFavorite)
        }
    }

    @Test func `series state aggregates across copies`() throws {
        try OnDiskCatalogStore.withContext { context in
            let english = series("1", "EN | Dark (2017)", in: context)
            let german = series("2", "DE | Dark (2017)", playlist: Self.second, in: context)
            german.isFavorite = true
            english.lastWatchedDate = Date(timeIntervalSince1970: 5000)
            try context.save()

            #expect(english.titleGroupKey == german.titleGroupKey)
            let key = try #require(english.titleGroupKey)
            let state = TitleGroupStateLookup.series(keys: [key], in: context)[key]
            #expect(state?.isFavorite == true)
            #expect(state?.lastWatched?.rowID == english.id)
        }
    }

    // MARK: Toggle off

    @Test func `unfavorite clears every copy, including ones matched by tmdb id`() throws {
        try OnDiskCatalogStore.withContext { context in
            let shown = movie("1", "Inception (2010) 4K", tmdbId: 27205, in: context)
            let sibling = movie("2", "Inception (2010) FHD", playlist: Self.second, tmdbId: 27205, in: context)
            let staleKey = movie("3", "Inception (2010) SD", tmdbId: 27205, in: context)
            staleKey.titleGroupKey = "t:inception|2010"
            let unrelated = movie("4", "Heat (1995)", in: context)
            for row in [shown, sibling, staleKey, unrelated] {
                row.isFavorite = true
                row.addedToWatchlistDate = Date()
            }
            sibling.favoriteOrder = 3
            try context.save()

            let changed = TitleGroupSiblings.unfavorite(shown, in: context)

            #expect(Set(changed.map(\.id)) == [shown.id, sibling.id, staleKey.id])
            for row in [shown, sibling, staleKey] {
                #expect(!row.isFavorite)
                #expect(row.addedToWatchlistDate == nil)
                #expect(row.favoriteOrder == nil)
            }
            #expect(unrelated.isFavorite)
        }
    }

    @Test func `toggle off reports only the rows it changed`() throws {
        try OnDiskCatalogStore.withContext { context in
            let shown = movie("1", "Inception (2010) 4K", in: context)
            let watched = movie("2", "Inception (2010) FHD", in: context)
            watched.isWatched = true
            watched.watchProgress = 500
            try context.save()

            let changed = TitleGroupSiblings.markUnwatched(shown, in: context)

            #expect(changed.map(\.id) == [watched.id])
            #expect(!watched.isWatched)
            #expect(watched.watchProgress == 500, "Progress stays, as for a single movie")
            #expect(TitleGroupSiblings.markUnwatched(shown, in: context).isEmpty)
        }
    }
}

//
//  ContentSyncSeriesFieldApplicationTests.swift
//  LumeTests
//
//  The series half of the dirty-checked provider-field application. Split from
//  ContentSyncFieldApplicationTests only to stay under the file-length limit;
//  the fixtures live there.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct ContentSyncSeriesFieldTests {
    @Test func `changed series fields are written`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-series-"
        let id = "\(playlistId.uuidString)-series-13855"

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let series = Series(id: id, seriesId: 13855, name: "Stale name")
        series.rating = "1"
        series.categoryId = prefix + "1"
        context.insert(series)
        try context.save()

        try await manager.applySeriesFields(from: FieldFixtures.decodeSeries(FieldFixtures.seriesJSON()), to: series, playlistPrefix: prefix)

        #expect(context.hasChanges, "A changed provider payload must dirty the context")
        #expect(series.name == "Acapulco")
        #expect(series.cover == "https://image.tmdb.org/t/p/w600_and_h900_bestv2/lU0RlcfBx6y0FSmEAq61ztjMgjt.jpg")
        #expect(series.plot == "In 1984, Maximo Gallardo lands the job of a lifetime at Las Colinas.")
        #expect(series.cast == "Eugenio Derbez, Enrique Arrizon, Raphael Alejandro")
        #expect(series.director == "Austin Winsberg, Jason Shuman")
        #expect(series.genre == "Comedy / Drama")
        #expect(series.releaseDate == "2021-10-08")
        #expect(series.lastModified == "1776621142")
        #expect(series.rating == "7")
        #expect(series.rating5Based == "1.4")
        #expect(series.tmdb == "90881")
        #expect(series.tmdbId == 90881)
        #expect(series.num == 1)
        #expect(series.categoryId == prefix + "434")
    }

    @Test func `unchanged series batch leaves the context clean`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-series-"
        let id = "\(playlistId.uuidString)-series-13855"
        let dto = try FieldFixtures.decodeSeries(FieldFixtures.seriesJSON())

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Series(id: id, seriesId: 13855, name: "")
        firstSync.insert(inserted)
        await manager.applySeriesFields(from: dto, to: inserted, playlistPrefix: prefix)
        try firstSync.save()

        // Second sync of the identical payload, through a fresh context exactly
        // as the batch loop builds one.
        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        ).first)
        await manager.applySeriesFields(from: dto, to: stored, playlistPrefix: prefix)

        #expect(!reSync.hasChanges, "An unchanged payload must not dirty the context — the save is then skipped")
    }

    @Test func `a provider genre seeds an unset series genre exactly once`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-series-"
        let id = "\(playlistId.uuidString)-series-13855"
        let dto = try FieldFixtures.decodeSeries(FieldFixtures.seriesJSON())

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Series(id: id, seriesId: 13855, name: "")
        firstSync.insert(inserted)
        #expect(inserted.genre == nil)
        await manager.applySeriesFields(from: dto, to: inserted, playlistPrefix: prefix)
        #expect(inserted.genre == "Comedy / Drama", "An unset genre must be seeded from the provider")
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        ).first)
        await manager.applySeriesFields(from: dto, to: stored, playlistPrefix: prefix)

        #expect(stored.genre == "Comedy / Drama")
        #expect(!reSync.hasChanges, "The seeded genre must not be rewritten on the next sync")
    }

    @Test func `a TMDB series genre is never overwritten and never dirties the context`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-series-"
        let id = "\(playlistId.uuidString)-series-13855"
        let dto = try FieldFixtures.decodeSeries(FieldFixtures.seriesJSON())

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Series(id: id, seriesId: 13855, name: "")
        firstSync.insert(inserted)
        await manager.applySeriesFields(from: dto, to: inserted, playlistPrefix: prefix)
        // TMDB enrichment then takes ownership of the genre.
        inserted.genre = "Comedy, Drama"
        try firstSync.save()

        // The dirty check has to compare GenreParser.providerFallback's result:
        // comparing the raw "Comedy / Drama" would rewrite this row forever.
        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        ).first)
        await manager.applySeriesFields(from: dto, to: stored, playlistPrefix: prefix)

        #expect(stored.genre == "Comedy, Drama", "TMDB owns the genre; the provider must not overwrite it")
        #expect(!reSync.hasChanges)
    }

    @Test func `series nil and empty string transitions are written`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-series-"
        let id = "\(playlistId.uuidString)-series-13855"

        // The provider omitted these keys, so they store as nil.
        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Series(id: id, seriesId: 13855, name: "")
        firstSync.insert(inserted)
        try await manager.applySeriesFields(
            from: FieldFixtures.decodeSeries(FieldFixtures.seriesJSON(cast: "null", director: "null", tmdb: "null")),
            to: inserted,
            playlistPrefix: prefix
        )
        try firstSync.save()
        #expect(inserted.cast == nil)
        #expect(inserted.tmdbId == nil, "An absent provider tmdb must leave the resolved id alone")

        // Most rows in a real payload carry "" here, not null.
        let toEmpty = ModelContext(container)
        toEmpty.autosaveEnabled = false
        let stored = try #require(try toEmpty.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        ).first)
        try await manager.applySeriesFields(
            from: FieldFixtures.decodeSeries(FieldFixtures.seriesJSON(cast: "\"\"", director: "\"\"", tmdb: "\"\"")),
            to: stored,
            playlistPrefix: prefix
        )
        #expect(toEmpty.hasChanges, "nil → \"\" is a real change and must be written")
        #expect(stored.cast == "")
        #expect(stored.director == "")
        #expect(stored.tmdb == "")
        try toEmpty.save()

        let toNil = ModelContext(container)
        toNil.autosaveEnabled = false
        let reFetched = try #require(try toNil.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        ).first)
        try await manager.applySeriesFields(
            from: FieldFixtures.decodeSeries(FieldFixtures.seriesJSON(cast: "null", director: "null", tmdb: "null")),
            to: reFetched,
            playlistPrefix: prefix
        )
        #expect(toNil.hasChanges, "\"\" → nil is a real change and must be written")
        #expect(reFetched.cast == nil)
        #expect(reFetched.director == nil)
        #expect(reFetched.tmdb == nil)
    }

    @Test func `a series payload without a category leaves the stored category alone`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-series-"
        let id = "\(playlistId.uuidString)-series-13855"

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Series(id: id, seriesId: 13855, name: "")
        firstSync.insert(inserted)
        try await manager.applySeriesFields(from: FieldFixtures.decodeSeries(FieldFixtures.seriesJSON()), to: inserted, playlistPrefix: prefix)
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        ).first)
        try await manager.applySeriesFields(
            from: FieldFixtures.decodeSeries(FieldFixtures.seriesJSON(categoryId: "null")),
            to: stored,
            playlistPrefix: prefix
        )

        #expect(stored.categoryId == prefix + "434")
        #expect(!reSync.hasChanges)
    }

    @Test func `series user state and enrichment survive a re-sync`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-series-"
        let id = "\(playlistId.uuidString)-series-13855"
        let watched = Date(timeIntervalSince1970: 1_000_000)
        let addedToWatchlist = Date(timeIntervalSince1970: 2_000_000)
        let enriched = Date(timeIntervalSince1970: 3_000_000)

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Series(id: id, seriesId: 13855, name: "")
        firstSync.insert(inserted)
        // tmdb absent, as the measured provider sends it: the resolved id and
        // the rest of the enrichment are then TMDB's alone.
        try await manager.applySeriesFields(
            from: FieldFixtures.decodeSeries(FieldFixtures.seriesJSON(tmdb: "null")),
            to: inserted,
            playlistPrefix: prefix
        )
        seedUserState(on: inserted, in: firstSync, watched: watched, watchlisted: addedToWatchlist, enriched: enriched)
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        ).first)
        try await manager.applySeriesFields(
            from: FieldFixtures.decodeSeries(FieldFixtures.seriesJSON(name: "Acapulco (2021)", tmdb: "null")),
            to: stored,
            playlistPrefix: prefix
        )
        try reSync.save()

        let verify = ModelContext(container)
        let result = try #require(try verify.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        ).first)
        #expect(result.name == "Acapulco (2021)", "The provider rename must land")
        #expect(result.isFavorite)
        #expect(result.favoriteOrder == 4)
        #expect(result.lastWatchedDate == watched)
        #expect(result.addedToWatchlistDate == addedToWatchlist)
        #expect(result.genre == "Comedy, Drama")
        #expect(result.backdropPath == "/backdrop.jpg")
        #expect(result.tagline == "Welcome to Las Colinas")
        #expect(result.tmdbId == 90881)
        #expect(result.tmdbEnrichedAt == enriched)
        #expect(result.episodes.first?.watchProgress == 900)
    }

    /// Everything a re-sync must leave alone: the series' own user state, the
    /// TMDB enrichment that outranks the provider, and an episode carrying watch
    /// progress (series deletes cascade to episodes, so their state rides along).
    private func seedUserState(
        on series: Series,
        in context: ModelContext,
        watched: Date,
        watchlisted: Date,
        enriched: Date
    ) {
        series.isFavorite = true
        series.favoriteOrder = 4
        series.lastWatchedDate = watched
        series.addedToWatchlistDate = watchlisted
        series.genre = "Comedy, Drama"
        series.backdropPath = "/backdrop.jpg"
        series.tagline = "Welcome to Las Colinas"
        series.tmdbId = 90881
        series.tmdbEnrichedAt = enriched

        let episode = Episode(
            id: "\(series.id)-s1e1",
            episodeId: "1",
            title: "Pilot",
            containerExtension: "mkv",
            seasonNum: 1,
            episodeNum: 1,
            series: series
        )
        episode.watchProgress = 900
        context.insert(episode)
    }
}

//
//  M3USeriesFieldApplicationTests.swift
//  LumeTests
//
//  The series half of the dirty-checked m3u field application: an unchanged
//  re-sync must leave the context clean — that is what lets `importBatch` skip
//  the save — while every real provider change, including nil ⇄ "", must still
//  be written. Split from M3UFieldApplicationTests only to stay under the
//  file-length limit; the fixtures live there.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

extension M3UFieldFixtures {
    static func episodeEntry(
        name: String = "Breaking Bad S01E01 Pilot",
        url: String = "http://provider.example.com/series/u/p/2001.mkv",
        logo: String? = "http://provider.example.com/covers/breakingbad.png",
        group: String? = "Series | Crime"
    ) -> M3UEntry {
        M3UEntry(name: name, url: url, tvgId: nil, logo: logo, group: group, type: nil)
    }
}

// MARK: - Series

struct M3USeriesFieldTests {
    /// Swift Testing runs this before every test in the suite. The m3u digest is
    /// device-local `UserDefaults` state that outlives a test, so each case
    /// starts from a clean slate rather than inheriting a sibling's fingerprint.
    init() {
        clearM3UDigests()
    }

    private static let category = "\(UUID().uuidString)-series-Series | Crime"
    private static let otherCategory = "\(UUID().uuidString)-series-Series | Drama"

    /// Stores `stored` through one context, then re-applies `next` through a
    /// *fresh* one — every import batch builds its own — and reports whether
    /// that second application dirtied it.
    private func reapply(
        stored: M3UEntry,
        storedCategoryId: String,
        next: M3UEntry,
        nextCategoryId: String
    ) async throws -> (dirty: Bool, series: Series) {
        let container = try makeTestContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let seriesId = "series-row"

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Series(id: seriesId, seriesId: 1, name: "Breaking Bad")
        firstSync.insert(inserted)
        await manager.applyM3USeriesFields(from: stored, to: inserted, categoryId: storedCategoryId)
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let row = try #require(try reSync.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == seriesId })
        ).first)
        await manager.applyM3USeriesFields(from: next, to: row, categoryId: nextCategoryId)
        return (reSync.hasChanges, row)
    }

    @Test func `changed series fields are written`() async throws {
        let container = try makeTestContainer()
        let manager = ContentSyncManager(modelContainer: container)

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let series = Series(id: "series-row", seriesId: 1, name: "Breaking Bad")
        series.categoryId = Self.otherCategory
        context.insert(series)
        try context.save()

        await manager.applyM3USeriesFields(
            from: M3UFieldFixtures.episodeEntry(),
            to: series,
            categoryId: Self.category
        )

        #expect(context.hasChanges, "A changed entry must dirty the context")
        #expect(series.categoryId == Self.category)
        #expect(series.cover == "http://provider.example.com/covers/breakingbad.png")
    }

    @Test func `unchanged series entry leaves the context clean`() async throws {
        let entry = M3UFieldFixtures.episodeEntry()
        let result = try await reapply(
            stored: entry,
            storedCategoryId: Self.category,
            next: entry,
            nextCategoryId: Self.category
        )

        #expect(!result.dirty, "An unchanged entry must not dirty the context — the save is then skipped")
        #expect(result.series.categoryId == Self.category)
        #expect(result.series.cover == "http://provider.example.com/covers/breakingbad.png")
    }

    @Test func `a changed group title dirties the context`() async throws {
        let entry = M3UFieldFixtures.episodeEntry()
        let result = try await reapply(
            stored: entry,
            storedCategoryId: Self.category,
            next: entry,
            nextCategoryId: Self.otherCategory
        )

        #expect(result.dirty, "A changed group-title must be written")
        #expect(result.series.categoryId == Self.otherCategory)
    }

    @Test func `a stored series cover is never overwritten`() async throws {
        var reArted = M3UFieldFixtures.episodeEntry()
        reArted.logo = "http://provider.example.com/covers/breakingbad-s2.png"

        let result = try await reapply(
            stored: M3UFieldFixtures.episodeEntry(),
            storedCategoryId: Self.category,
            next: reArted,
            nextCategoryId: Self.category
        )

        #expect(result.series.cover == "http://provider.example.com/covers/breakingbad.png")
        #expect(!result.dirty, "A later episode's artwork must not replace the cover TMDB then owns")
    }

    @Test func `a series without artwork keeps consulting later episodes`() async throws {
        let result = try await reapply(
            stored: M3UFieldFixtures.episodeEntry(logo: nil),
            storedCategoryId: Self.category,
            next: M3UFieldFixtures.episodeEntry(),
            nextCategoryId: Self.category
        )

        #expect(result.dirty, "An unset cover must be seeded by the first episode that carries artwork")
        #expect(result.series.cover == "http://provider.example.com/covers/breakingbad.png")
    }

    @Test func `series nil and empty attributes are distinct`() async throws {
        // categoryId: an entry with no group-title resolves to the
        // "Uncategorized" id, so "" only ever reaches here as a real change.
        let container = try makeTestContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let seriesId = "series-row"
        let entry = M3UFieldFixtures.episodeEntry(logo: nil)

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Series(id: seriesId, seriesId: 1, name: "Breaking Bad")
        firstSync.insert(inserted)
        #expect(inserted.categoryId == nil)
        await manager.applyM3USeriesFields(from: entry, to: inserted, categoryId: "")
        #expect(inserted.categoryId == "", "nil → \"\" is a real change and must be written")
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == seriesId })
        ).first)
        await manager.applyM3USeriesFields(from: entry, to: stored, categoryId: "")
        #expect(!reSync.hasChanges)

        // A cover is seeded from an empty tvg-logo too: "" and nil are distinct
        // values, and only nil counts as "no cover yet".
        let seedEmpty = try await reapply(
            stored: M3UFieldFixtures.episodeEntry(logo: nil),
            storedCategoryId: Self.category,
            next: M3UFieldFixtures.episodeEntry(logo: ""),
            nextCategoryId: Self.category
        )
        #expect(seedEmpty.dirty, "nil → \"\" is a real change and must be written")
        #expect(seedEmpty.series.cover == "")
    }

    @Test func `a re-imported 2,000-episode series writes its category at most once`() async throws {
        let container = try makeTestContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let seriesId = "series-row"
        // The measured provider file names the same group title once per
        // episode, up to 2,799 times for a single show.
        let entries = (0 ..< 2000).map { index in
            M3UFieldFixtures.episodeEntry(
                name: "Breaking Bad S01E\(index)",
                url: "http://provider.example.com/series/u/p/\(index).mkv"
            )
        }

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Series(id: seriesId, seriesId: 1, name: "Breaking Bad")
        firstSync.insert(inserted)
        for entry in entries {
            await manager.applyM3USeriesFields(from: entry, to: inserted, categoryId: Self.category)
        }
        try firstSync.save()
        #expect(inserted.categoryId == Self.category)

        // The provider moves the show to another group: the first episode of
        // the batch writes the new category, and the remaining 1,999 must not
        // write it again.
        let moved = ModelContext(container)
        moved.autosaveEnabled = false
        let row = try #require(try moved.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == seriesId })
        ).first)
        await manager.applyM3USeriesFields(from: entries[0], to: row, categoryId: Self.otherCategory)
        #expect(moved.hasChanges, "The group-title change itself must be written")
        try moved.save()
        for entry in entries.dropFirst() {
            await manager.applyM3USeriesFields(from: entry, to: row, categoryId: Self.otherCategory)
        }
        #expect(!moved.hasChanges, "Only the batch's first episode may write the series category")

        // An unchanged re-import writes it zero times.
        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let reSynced = try #require(try reSync.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == seriesId })
        ).first)
        for entry in entries {
            await manager.applyM3USeriesFields(from: entry, to: reSynced, categoryId: Self.otherCategory)
        }
        #expect(!reSync.hasChanges, "A re-imported series must not be re-written once per episode")
    }
}

// MARK: - Episodes

struct M3UEpisodeFieldTests {
    /// Swift Testing runs this before every test in the suite. The m3u digest is
    /// device-local `UserDefaults` state that outlives a test, so each case
    /// starts from a clean slate rather than inheriting a sibling's fingerprint.
    init() {
        clearM3UDigests()
    }

    private func reapply(
        stored: M3UEntry,
        storedTitle: String,
        next: M3UEntry,
        nextTitle: String
    ) async throws -> (dirty: Bool, episode: Episode) {
        let container = try makeTestContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let episodeId = "episode-row"

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Episode(
            id: episodeId,
            episodeId: "2001",
            title: "",
            containerExtension: "mkv",
            seasonNum: 1,
            episodeNum: 1
        )
        firstSync.insert(inserted)
        await manager.applyM3UEpisodeFields(from: stored, title: storedTitle, to: inserted)
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let row = try #require(try reSync.fetch(
            FetchDescriptor<Episode>(predicate: #Predicate { $0.id == episodeId })
        ).first)
        await manager.applyM3UEpisodeFields(from: next, title: nextTitle, to: row)
        return (reSync.hasChanges, row)
    }

    @Test func `changed episode fields are written`() async throws {
        let container = try makeTestContainer()
        let manager = ContentSyncManager(modelContainer: container)

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let episode = Episode(
            id: "episode-row",
            episodeId: "2001",
            title: "Stale title",
            containerExtension: "mkv",
            seasonNum: 1,
            episodeNum: 1
        )
        context.insert(episode)
        try context.save()

        await manager.applyM3UEpisodeFields(from: M3UFieldFixtures.episodeEntry(), title: "Pilot", to: episode)

        #expect(context.hasChanges, "A changed entry must dirty the context")
        #expect(episode.title == "Pilot")
        #expect(episode.directSource == "http://provider.example.com/series/u/p/2001.mkv")
        #expect(episode.movieImage == "http://provider.example.com/covers/breakingbad.png")
    }

    @Test func `unchanged episode entry leaves the context clean`() async throws {
        let entry = M3UFieldFixtures.episodeEntry()
        let result = try await reapply(stored: entry, storedTitle: "Pilot", next: entry, nextTitle: "Pilot")

        #expect(!result.dirty, "An unchanged entry must not dirty the context — the save is then skipped")
        #expect(result.episode.title == "Pilot")
        #expect(result.episode.directSource == "http://provider.example.com/series/u/p/2001.mkv")
    }

    @Test func `each changed episode field dirties the context`() async throws {
        let base = M3UFieldFixtures.episodeEntry()
        var reURLed = base
        reURLed.url = "http://provider.example.com/series/u/p/2002.mkv"
        var reArted = base
        reArted.logo = "http://provider.example.com/covers/breakingbad-s2.png"

        let cases: [(field: String, entry: M3UEntry, title: String)] = [
            ("title", base, "Pilot (Remastered)"),
            ("url", reURLed, "Pilot"),
            ("tvg-logo", reArted, "Pilot")
        ]

        for change in cases {
            let result = try await reapply(
                stored: base,
                storedTitle: "Pilot",
                next: change.entry,
                nextTitle: change.title
            )
            #expect(result.dirty, "A changed \(change.field) must be written")
        }
    }

    @Test func `episode nil and empty attributes are distinct`() async throws {
        let absent = M3UFieldFixtures.episodeEntry(logo: nil)
        let empty = M3UFieldFixtures.episodeEntry(logo: "")

        let toEmpty = try await reapply(stored: absent, storedTitle: "Pilot", next: empty, nextTitle: "Pilot")
        #expect(toEmpty.dirty, "nil → \"\" is a real change and must be written")
        #expect(toEmpty.episode.movieImage == "")

        let toNil = try await reapply(stored: empty, storedTitle: "Pilot", next: absent, nextTitle: "Pilot")
        #expect(toNil.dirty, "\"\" → nil is a real change and must be written")
        #expect(toNil.episode.movieImage == nil)

        let unchanged = try await reapply(stored: empty, storedTitle: "Pilot", next: empty, nextTitle: "Pilot")
        #expect(!unchanged.dirty)

        // A token-first title ("S01E01 Pilot") leaves nothing after the token,
        // so the empty title an entry like that derives must stay distinct from
        // the name it replaced.
        let toEmptyTitle = try await reapply(stored: absent, storedTitle: "Pilot", next: absent, nextTitle: "")
        #expect(toEmptyTitle.dirty)
        #expect(toEmptyTitle.episode.title == "")
    }
}

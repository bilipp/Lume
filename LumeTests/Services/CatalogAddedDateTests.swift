//
//  CatalogAddedDateTests.swift
//  LumeTests
//
//  Every source's "added" stamp must land as the same 10-digit Unix string, or
//  the binary sort behind Recently Added ranks one source's dates above
//  another's.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct CatalogAddedDateTests {
    @Test func `unix seconds pass through, padded to ten digits`() {
        #expect(CatalogAddedDate.unixString("1704103200") == "1704103200")
        #expect(CatalogAddedDate.unixString("999999999") == "0999999999")
        #expect(CatalogAddedDate.unixString("0") == "0000000000")
        #expect(CatalogAddedDate.unixString(" 1704103200\n") == "1704103200")
    }

    @Test func `millisecond stamps drop to seconds`() {
        #expect(CatalogAddedDate.unixString("1704103200123") == "1704103200")
    }

    @Test func `a bare date is midnight UTC`() {
        #expect(CatalogAddedDate.unixString("2024-01-01") == "1704067200")
        #expect(CatalogAddedDate.unixString("2024-02-29") == "1709164800")
        #expect(CatalogAddedDate.unixString("1970-01-01") == "0000000000")
    }

    @Test func `a Stalker stamp without a zone is read as UTC`() {
        #expect(CatalogAddedDate.unixString("2024-01-01 10:00:00") == "1704103200")
        #expect(CatalogAddedDate.unixString("2024-01-01 10:00") == "1704103200")
    }

    @Test func `ISO-8601 with fraction and zone`() {
        #expect(CatalogAddedDate.unixString("2026-09-17T09:51:37.0000000Z") == "1789638697")
        #expect(CatalogAddedDate.unixString("2026-09-17T09:51:37Z") == "1789638697")
        #expect(CatalogAddedDate.unixString("2026-09-17T09:51:37") == "1789638697")
        #expect(CatalogAddedDate.unixString("2026-09-17T11:51:37+02:00") == "1789638697")
        #expect(CatalogAddedDate.unixString("2026-09-17T07:51:37.5-0200") == "1789638697")
        #expect(CatalogAddedDate.unixString("2026-09-17T11:51:37+02") == "1789638697")
    }

    @Test func `unreadable stamps are nil`() {
        #expect(CatalogAddedDate.unixString(nil) == nil)
        #expect(CatalogAddedDate.unixString("") == nil)
        #expect(CatalogAddedDate.unixString("   ") == nil)
        #expect(CatalogAddedDate.unixString("0000-00-00 00:00:00") == nil)
        #expect(CatalogAddedDate.unixString("2023-02-29") == nil)
        #expect(CatalogAddedDate.unixString("2024-13-01") == nil)
        #expect(CatalogAddedDate.unixString("2024-01-01 25:00:00") == nil)
        #expect(CatalogAddedDate.unixString("2024-01-01X10:00:00") == nil)
        #expect(CatalogAddedDate.unixString("2024-01-01 10:00:00 junk") == nil)
        #expect(CatalogAddedDate.unixString("17041032001") == nil)
        #expect(CatalogAddedDate.unixString("-5") == nil)
        #expect(CatalogAddedDate.unixString("1969-12-31") == nil)
        #expect(CatalogAddedDate.unixString("yesterday") == nil)
    }

    @Test func `the canonical form is idempotent`() {
        for raw in ["1704103200", "2024-01-01 10:00:00", "2026-09-17T09:51:37.0000000Z", "42"] {
            let once = CatalogAddedDate.unixString(raw)
            #expect(CatalogAddedDate.unixString(once) == once)
            #expect(once?.utf8.count == CatalogAddedDate.width)
        }
    }

    @Test func `unix seconds out of the ten-digit range are nil`() {
        #expect(CatalogAddedDate.unixString(seconds: -1) == nil)
        #expect(CatalogAddedDate.unixString(seconds: 10_000_000_000) == nil)
        #expect(CatalogAddedDate.unixString(seconds: 1_000_000_000) == "1000000000")
    }

    @Test func `lexical order of normalised stamps is chronological across sources`() {
        let stalker = CatalogAddedDate.unixString("2024-01-01 10:00:00") ?? ""
        let jellyfin = CatalogAddedDate.unixString("2023-06-01T00:00:00Z") ?? ""
        let xtream = CatalogAddedDate.unixString("1704103300") ?? ""
        let legacy = CatalogAddedDate.unixString("999999999") ?? ""
        #expect([stalker, jellyfin, xtream, legacy].sorted() == [legacy, jellyfin, stalker, xtream])
    }

    @Test func `same instant matches across formats only for readable stamps`() {
        #expect(CatalogAddedDate.sameInstant("2024-01-01 10:00:00", "1704103200"))
        #expect(CatalogAddedDate.sameInstant(nil, nil))
        #expect(CatalogAddedDate.sameInstant("junk", "junk"))
        #expect(!CatalogAddedDate.sameInstant("junk", "trash"))
        #expect(!CatalogAddedDate.sameInstant("1704103200", nil))
        #expect(!CatalogAddedDate.sameInstant("1704103200", "1704103201"))
    }

    @Test func `an Xtream row already stored in the canonical form stays clean`() async throws {
        let container = try FieldFixtures.makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let manager = ContentSyncManager(modelContainer: container)
        let dto = try FieldFixtures.decodeMovie(FieldFixtures.movieJSON(added: "\"999999999\""))
        let movie = Movie(id: "p-movie-7", streamId: 7, name: "")
        context.insert(movie)

        await manager.applyMovieFields(from: dto, to: movie, playlistPrefix: "p-vod-")
        #expect(movie.added == "0999999999")
        try context.save()
        await manager.applyMovieFields(from: dto, to: movie, playlistPrefix: "p-vod-")

        #expect(!context.hasChanges)
    }
}

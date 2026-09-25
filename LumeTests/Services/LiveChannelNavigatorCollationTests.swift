//
//  LiveChannelNavigatorCollationTests.swift
//  LumeTests
//
//  `LiveChannelNavigator.Ring` never reads a channel list whole: it bisects for
//  the playing channel's position, pulling one row at a time out of an ordering
//  SQLite applies and comparing each row it reads in *Swift*, through
//  `SortDescriptor.compare`. That is only correct while the two orderings agree,
//  and the places they can part company are exactly the ones a plain unit test
//  never reaches: a localized collation, a NULL in an optional sort key, a run
//  of rows that ties on every key there is.
//
//  An in-memory `ModelContainer` evaluates the sort in Swift too, so
//  `makeTestContainer()` cannot show a disagreement even in principle. These
//  cases run against a real store file (`OnDiskCatalogStore`) and take every
//  expectation from a whole-list fetch of the same descriptor the ring walks —
//  never from a hand-written ordering, which would only pin this file's guess
//  about the collation rather than SQLite's answer.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct LiveChannelNavigatorCollationTests {
    /// One channel to seed.
    private struct StreamSpec {
        var name: String
        var num = 0
        var customOrder: Int?
        var favoriteOrder: Int?
        var isFavorite = false
    }

    private let restriction = ContentRestriction()

    // MARK: - Fixture

    /// Seeds `specs` into `context` and hands back the owning playlist.
    @discardableResult
    private func seed(_ specs: [StreamSpec], in context: ModelContext) throws -> Playlist {
        let playlist = Playlist(
            name: "Test",
            serverURL: "http://example.com:8080",
            username: "user",
            password: "pass"
        )
        context.insert(playlist)
        let category = categoryID(playlist)
        for (index, spec) in specs.enumerated() {
            // Ids follow the scheme `ContentSyncManager` writes —
            // "<playlistUUID>-live-<streamId>" — which is what the ring's
            // playlist-prefix predicate and `PlaylistOwner` key off.
            let stream = LiveStream(
                id: "\(playlist.id.uuidString)-live-\(1000 + index)",
                streamId: 1000 + index,
                name: spec.name,
                num: spec.num,
                categoryId: category
            )
            stream.customOrder = spec.customOrder
            stream.favoriteOrder = spec.favoriteOrder
            stream.isFavorite = spec.isFavorite
            context.insert(stream)
        }
        try context.save()
        return playlist
    }

    private func categoryID(_ playlist: Playlist) -> String {
        "\(playlist.id.uuidString)-live-cat"
    }

    /// The scope in the order SQLite actually places it — the ring's own
    /// descriptor, fetched whole, which is the one thing the ring never does.
    private func sqliteOrder(
        scope: LiveChannelScope,
        sort: ContentSortOption,
        playlist: Playlist,
        in context: ModelContext
    ) throws -> [LiveStream] {
        try context.fetch(LiveChannelNavigator.scopeDescriptor(
            scope: scope,
            sort: sort,
            playlistPrefix: "\(playlist.id.uuidString)-",
            restriction: restriction,
            admittingHidden: nil
        ))
    }

    private func nextID(
        after stream: LiveStream,
        scope: LiveChannelScope,
        sort: ContentSortOption,
        playlist: Playlist,
        in context: ModelContext
    ) throws -> String? {
        let current = try #require(
            PlayableMedia.from(stream: stream, playlist: playlist, scope: scope)
        )
        guard let next = LiveChannelNavigator.adjacentMedia(
            for: current, offset: 1, sort: sort, restriction: restriction, in: context
        ) else { return nil }
        guard case let .live(id) = next.contentRef else { return nil }
        return id
    }

    /// Every position of a scope, walked one press at a time, against the row
    /// SQLite places after it.
    private func expectRingFollowsSQLite(
        scope: LiveChannelScope,
        sort: ContentSortOption,
        playlist: Playlist,
        in context: ModelContext
    ) throws {
        let ordered = try sqliteOrder(scope: scope, sort: sort, playlist: playlist, in: context)
        #expect(ordered.count > 1)
        for (index, stream) in ordered.enumerated() {
            let walked = try nextID(
                after: stream, scope: scope, sort: sort, playlist: playlist, in: context
            )
            let expected = ordered[(index + 1) % ordered.count]
            #expect(
                walked == expected.id,
                "from \"\(stream.name)\" (position \(index)) expected \"\(expected.name)\""
            )
        }
    }

    // MARK: - Collation

    /// Names chosen to land on every axis `localizedStandardCompare` treats
    /// specially and an ASCII byte comparison does not: case-only differences,
    /// diacritics, leading punctuation and whitespace, and numeric prefixes that
    /// sort by value rather than by digit.
    @Test func `name sorted ring follows SQLite's collation`() throws {
        let names = [
            "abc", "ABC", "Abc",
            "Elan", "Élan", "élan",
            "+Sports", "4K Sport", "10 Sport", " Sport", "Sport", "sport TV"
        ]
        try OnDiskCatalogStore.withContext { context in
            let playlist = try seed(names.map { StreamSpec(name: $0) }, in: context)
            try expectRingFollowsSQLite(
                scope: .category(categoryID(playlist)),
                sort: .nameAscending,
                playlist: playlist,
                in: context
            )
        }
    }

    // MARK: - Ties

    /// Provider lineups repeat a name across a whole block of channels, and
    /// under `.playlist` an un-reordered category ties on `customOrder` and
    /// `num` as well — so a run can tie on every key the sort has. The run here
    /// is deliberately longer than the ring's tie page, the granularity a tied
    /// run is read at: a press from beyond the first page still has to move.
    @Test func `surfing inside a fully tied run still moves`() throws {
        let runLength = 80
        try OnDiskCatalogStore.withContext { context in
            let playlist = try seed(
                Array(repeating: StreamSpec(name: "Sport"), count: runLength), in: context
            )
            let scope = LiveChannelScope.category(categoryID(playlist))
            let ordered = try sqliteOrder(
                scope: scope, sort: .playlist, playlist: playlist, in: context
            )
            #expect(ordered.count == runLength)

            let reachable = Set(ordered.map(\.id))
            // Positions on both sides of the 64-row tie page, plus the ends of
            // the run: a single-page tie walk made every press past it do
            // nothing at all.
            for index in [0, 1, 63, 64, 65, runLength - 2, runLength - 1] {
                let walked = try nextID(
                    after: ordered[index], scope: scope, sort: .playlist,
                    playlist: playlist, in: context
                )
                let landed = try #require(walked, "surfing stopped at position \(index)")
                #expect(reachable.contains(landed), "position \(index) surfed out of its own list")
                #expect(landed != ordered[index].id, "position \(index) surfed to itself")
            }
        }
    }

    // MARK: - NULLs

    /// `customOrder` and `favoriteOrder` are both optional and both lead their
    /// sort, so where SQLite puts a NULL decides the top of the list. The Swift
    /// comparison the ring bisects with has to put it in the same place.
    @Test func `ring follows SQLite's placement of null order keys`() throws {
        let specs = [
            StreamSpec(name: "Alpha", num: 4, customOrder: nil, favoriteOrder: 2, isFavorite: true),
            StreamSpec(name: "Bravo", num: 1, customOrder: 3, favoriteOrder: nil, isFavorite: true),
            StreamSpec(name: "Charlie", num: 5, customOrder: nil, favoriteOrder: nil, isFavorite: true),
            StreamSpec(name: "Delta", num: 2, customOrder: 1, favoriteOrder: 4, isFavorite: true),
            StreamSpec(name: "Echo", num: 6, customOrder: nil, favoriteOrder: 3, isFavorite: true),
            StreamSpec(name: "Foxtrot", num: 3, customOrder: 2, favoriteOrder: nil, isFavorite: true)
        ]
        try OnDiskCatalogStore.withContext { context in
            let playlist = try seed(specs, in: context)
            try expectRingFollowsSQLite(
                scope: .category(categoryID(playlist)),
                sort: .playlist,
                playlist: playlist,
                in: context
            )
            try expectRingFollowsSQLite(
                scope: .favorites,
                sort: .playlist,
                playlist: playlist,
                in: context
            )
        }
    }
}

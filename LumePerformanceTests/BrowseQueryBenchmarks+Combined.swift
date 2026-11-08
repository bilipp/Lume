//
//  BrowseQueryBenchmarks+Combined.swift
//  LumePerformanceTests
//
//  The browse fetches a Combined selection adds on top of `BrowseQueryBenchmarks`:
//  a rail, a section gate and a channel surf, each with the playlist scope as
//  `CatalogScope`'s `Predicate.evaluate` OR fold over several members instead of
//  one `id.starts(with:)`.
//
//  What they guard is the same class of invisible regression as the isolated
//  set, plus one of their own: a rewrite that fetches each member separately and
//  merges in Swift shows exactly the right rows, and pays one query per member
//  plus a main-actor merge for it — for a positional read it is not even
//  correct. The deterministic half of that guard is
//  `LumeTests/Services/CatalogScopeShapeTests.swift`.
//
//  Its own class and fixture, so the isolated baselines are not moved by rows
//  their fetches never read. Three playlists in priority order: A and B
//  contribute every type, C contributes Movies only — so the movie rail folds
//  three prefixes while every Live TV fetch has C's channels to exclude.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

final class CombinedBrowseQueryBenchmarks: XCTestCase {
    private var store: (container: ModelContainer, directory: URL)!

    /// Members in priority order: A, B, C.
    private var memberIDs: [UUID] = []
    private var scope = CatalogScope.empty

    private let moviesPerMember = 15000
    private let channelsPerMember = 6000
    /// The surf list per Live TV member; A and B together make the same
    /// 4,000-channel list `testChannelSurfResolution` walks in isolation.
    private let surfChannelsPerMember = 2000

    private var hiddenEvery: Int {
        19
    }

    /// Favorites in B only, never in A: the probe's first member contributes
    /// nothing, so the fold has to reach past it. C holds four times as many,
    /// none of which may answer.
    private var memberFavoriteEvery: Int {
        40
    }

    private var excludedFavoriteEvery: Int {
        10
    }

    /// See `BrowseQueryBenchmarks.probeRepeats`.
    private let probeRepeats = 25

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try PerfStore.makeOnDiskContainer()
        seedCatalog()
    }

    override func tearDownWithError() throws {
        if let store {
            PerfStore.destroy(directory: store.directory)
        }
        store = nil
        try super.tearDownWithError()
    }

    // MARK: - Benchmarks

    /// "Recently Added" on Movies with all three members contributing. The
    /// isolated rail is an index walk on `Movie.added` stopped by `LIMIT`; this
    /// is the same walk with a three-way OR on `id` as the filter. Guards that
    /// the fold stays in SQL with the `added` order and the limit — losing
    /// `comparator: .lexical` or the limit costs here what it costs in
    /// `testRecentlyAddedMovieRail`, three times over.
    func testRecentlyAddedMovieRailCombined() {
        let descriptor = MovieCollectionQuery.rowDescriptor(for: .recentlyAdded, scope: scope)
        let context = ModelContext(store.container)
        let prefixes = scope.prefixes(for: .movies)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let rows = (try? context.fetch(descriptor)) ?? []
            XCTAssertEqual(rows.count, collectionRowFetchLimit)
            let owners = Set(rows.compactMap { row in prefixes.firstIndex { row.id.hasPrefix($0) } })
            XCTAssertEqual(owners.count, prefixes.count)
        }
    }

    /// The Live TV Favorites gate across the members contributing Live TV. Same
    /// `LIMIT 1`, no-sort shape as `testLiveFavoritesProbe`, with the playlist
    /// scope as an `evaluate` fold over A and B. The priority-1 member has no
    /// favorites and the non-contributing C has the most, so a probe that lost
    /// its scope answers from C — a wrong row, which the assertion catches.
    func testLiveFavoritesProbeCombined() throws {
        let descriptor = LiveChannelQuery.favoritesProbe(catalogScope: scope, restriction: ContentRestriction())
        let context = ModelContext(store.container)
        let memberPrefix = try "\(XCTUnwrap(memberIDs.dropFirst().first).uuidString)-"

        measure(metrics: [XCTClockMetric()]) {
            for _ in 0 ..< probeRepeats {
                let rows = (try? context.fetch(descriptor)) ?? []
                XCTAssertEqual(rows.count, 1)
                XCTAssertTrue(rows.first?.id.hasPrefix(memberPrefix) == true)
            }
        }
    }

    /// One stream change launched from Combined Favorites: both neighbours of a
    /// channel in the middle of A and B's merged 4,000-channel favorites list,
    /// with C's favorites seeded alongside and excluded. Guards that the ring
    /// stays positional in SQL through the fold — a rewrite that fetched each
    /// member and merged in Swift still surfs to the right channel, with both
    /// full lists materialized on the main actor during playback. Compare with
    /// `testChannelSurfResolution`, the same list length in one playlist.
    func testChannelSurfResolutionCombinedFavorites() throws {
        seedSurfableFavorites()
        let context = ModelContext(store.container)
        let surfScope = try XCTUnwrap(LiveSurfScope(scope))
        let media = try surfMedia(at: surfChannelsPerMember / 2, surfScope: surfScope, in: context)
        let restriction = ContentRestriction()

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for _ in 0 ..< probeRepeats {
                let next = LiveChannelNavigator.adjacentMedia(
                    for: media, offset: 1, sort: .playlist, restriction: restriction, in: context
                )
                let previous = LiveChannelNavigator.adjacentMedia(
                    for: media, offset: -1, sort: .playlist, restriction: restriction, in: context
                )
                XCTAssertNotNil(next)
                XCTAssertNotNil(previous)
            }
        }
    }

    // MARK: - Seeding

    /// Seeded once per test in `setUp`, never inside a measured block. Content
    /// that varies per row comes from a fixed-seed generator, so every run
    /// builds the same store.
    private func seedCatalog() {
        let context = ModelContext(store.container)
        context.autosaveEnabled = false
        var generator = SeededGenerator(seed: 0xC0B1_4ED0_0000_0204)

        let playlists = ["A", "B", "C"].map {
            Playlist(name: "Member \($0)", serverURL: "http://perf.test", username: "u", password: "p")
        }
        playlists.forEach(context.insert)
        memberIDs = playlists.map(\.id)
        scope = .combined([
            (id: memberIDs[0], tabs: Set(PlaylistTab.allCases)),
            (id: memberIDs[1], tabs: Set(PlaylistTab.allCases)),
            (id: memberIDs[2], tabs: [.movies])
        ])

        for (rank, member) in memberIDs.enumerated() {
            seedMovies(for: member, using: &generator, in: context)
            seedChannels(for: member, rank: rank, in: context)
        }
        try? context.save()
    }

    /// `added` is the normalized ten-digit Unix second string, with a seeded
    /// jitter so the members' newest titles interleave rather than one member
    /// owning the top of the rail.
    private func seedMovies(for member: UUID, using generator: inout SeededGenerator, in context: ModelContext) {
        let prefix = "\(member.uuidString)-"
        autoreleasepool {
            for index in 0 ..< moviesPerMember {
                let jitter = Int(generator.next() % 600)
                context.insert(Movie(
                    id: "\(prefix)vod-\(index)",
                    streamId: index,
                    name: index.isMultiple(of: 3) ? "The Feature \(index)" : "Feature \(index)",
                    added: String(1_700_000_000 + index * 60 + jitter),
                    num: index,
                    categoryId: "\(prefix)vod-cat\(index % 200)"
                ))
            }
        }
    }

    private func seedChannels(for member: UUID, rank: Int, in context: ModelContext) {
        let prefix = "\(member.uuidString)-"
        let favoriteEvery: Int? = switch rank {
        case 1: memberFavoriteEvery
        case 2: excludedFavoriteEvery
        default: nil
        }
        autoreleasepool {
            for index in 0 ..< channelsPerMember {
                let stream = LiveStream(
                    id: "\(prefix)live-\(index)",
                    streamId: index,
                    name: "Channel \(index)",
                    num: index,
                    categoryId: "\(prefix)live-cat\(index % 200)"
                )
                stream.isHidden = index.isMultiple(of: hiddenEvery)
                if let favoriteEvery, index.isMultiple(of: favoriteEvery), !stream.isHidden {
                    stream.isFavorite = true
                    stream.favoriteOrder = index / favoriteEvery
                }
                context.insert(stream)
            }
        }
    }

    /// A favorites list in every playlist, C included. Seeded by the surf
    /// benchmark alone so the rail and probe numbers are not moved by it.
    private func seedSurfableFavorites() {
        let context = ModelContext(store.container)
        context.autosaveEnabled = false
        for member in memberIDs {
            let prefix = "\(member.uuidString)-"
            autoreleasepool {
                for index in 0 ..< surfChannelsPerMember {
                    let stream = LiveStream(
                        id: "\(prefix)live-surf\(index)",
                        streamId: 100_000 + index,
                        name: "Surf Channel \(index)",
                        num: 100_000 + index,
                        categoryId: "\(prefix)live-catsurf"
                    )
                    stream.isFavorite = true
                    stream.favoriteOrder = index
                    context.insert(stream)
                }
            }
        }
        try? context.save()
    }

    /// Member A's channel at `index` of the surf list, launched from Combined
    /// Favorites.
    private func surfMedia(
        at index: Int, surfScope: LiveSurfScope, in context: ModelContext
    ) throws -> PlayableMedia {
        let playlistID = try XCTUnwrap(memberIDs.first)
        let streamID = "\(playlistID.uuidString)-live-surf\(index)"
        var streamDescriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == streamID })
        streamDescriptor.fetchLimit = 1
        let stream = try XCTUnwrap(context.fetch(streamDescriptor).first)

        var playlistDescriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistID })
        playlistDescriptor.fetchLimit = 1
        let playlist = try XCTUnwrap(context.fetch(playlistDescriptor).first)

        return try XCTUnwrap(
            PlayableMedia.from(stream: stream, playlist: playlist, scope: .favorites, surfScope: surfScope)
        )
    }
}

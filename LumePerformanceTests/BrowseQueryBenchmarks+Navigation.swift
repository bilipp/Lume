//
//  BrowseQueryBenchmarks+Navigation.swift
//  LumePerformanceTests
//
//  The two lookups behind the player's previous/next transport buttons:
//  `LiveChannelNavigator.adjacentMedia` for a live channel and
//  `NextEpisodeResolver.nextMedia`/`.previousMedia` for an episode.
//
//  They are the newest members of the browse read path and they regress the same
//  invisible way everything else in `BrowseQueryBenchmarks` does. Both answered a
//  question about two rows by reading everything — the channel walk materialized
//  the whole scope, the episode walk faulted every installed `Playlist` — and a
//  rewrite that puts either back still tunes to exactly the right stream. The
//  cheap deterministic half of the guard is in
//  `LumeTests/Services/BrowseQueryShapeTests.swift`; this half is the cost.
//
//  Unlike the browse rails, these run *during playback*, on the main actor, once
//  per stream change — with a decoder being torn down and rebuilt alongside
//  them.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

extension BrowseQueryBenchmarks {
    /// The list one channel change is resolved within. A provider's live
    /// categories and a heavy viewer's favorites both run to thousands of
    /// channels; the whole point of the ring walk is that this number does not
    /// appear in the cost.
    private var surfChannelCount: Int {
        4000
    }

    /// Seasons on the long-running show the episode benchmark resolves inside —
    /// 480 episodes, near the p99 of the measured provider's per-show
    /// distribution (median 12, p99 279, largest 2,799).
    private var longRunSeasons: Int {
        20
    }

    /// Shows that carry episodes so the `Episode` table the playing episode is
    /// looked up in is a table worth seeking in rather than a handful of rows.
    private var episodeShowCount: Int {
        300
    }

    private var episodesPerShow: Int {
        24
    }

    /// One stream change's worth of channel surfing: both neighbours of the
    /// playing channel, the way the player host resolves them once per stream.
    ///
    /// The list is Favorites, because that is where the playlist scope has to be
    /// in the predicate. A category id already names its owning playlist, so a
    /// category walk cannot read another playlist's rows even with the prefix
    /// gone; a favorites walk reads both playlists' favorites the moment the
    /// prefix leaves SQL — wrong rows, not merely slow ones. Both playlists are
    /// seeded with a full list for that reason.
    ///
    /// What the cost guards is that the list is never materialized: this used to
    /// fetch the whole scope onto the main actor, find the playing channel's
    /// index in Swift and wrap it, to answer a question about two rows.
    ///
    /// Read the absolute number knowing what is in it. The walk reads ~14
    /// positions, and *every* positional read re-applies the scope's ORDER BY —
    /// which for `.playlist` ends in a `name` tiebreak under the default
    /// localized comparator, so SQLite sorts the matching rows each time. The
    /// number therefore still grows with the length of the list; what the
    /// rewrite took out is the materialization, not the sort. See the README.
    func testChannelSurfResolution() throws {
        seedSurfableFavorites()
        let context = ModelContext(store.container)
        let media = try surfMedia(at: surfChannelCount / 2, in: context)
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

    /// The episode equivalent: both neighbours of a season finale, which under
    /// series-wide ordering means the next season's premiere on one side and the
    /// finale's predecessor on the other.
    ///
    /// The `ModelContext` is built inside the loop, unlike every other benchmark
    /// in this file. A `FetchDescriptor` runs its SQL however warm the context
    /// is, but a relationship faults exactly once per context — a reused one
    /// would measure the walk of an already-materialized `Series.episodes` array
    /// from the second iteration on, which is precisely the cost this is here to
    /// watch.
    func testSeriesEpisodeResolution() throws {
        let finale = try seedEpisodes()

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for _ in 0 ..< probeRepeats {
                let context = ModelContext(store.container)
                let next = NextEpisodeResolver.nextMedia(after: finale, in: context)
                let previous = NextEpisodeResolver.previousMedia(before: finale, in: context)
                XCTAssertNotNil(next)
                XCTAssertNotNil(previous)
            }
        }
    }

    // MARK: Navigation seeding

    /// A full favorites list in *both* playlists. Seeded by the surf benchmark
    /// rather than in `seedCatalog` so the rest of the file's baselines are not
    /// moved by rows their fetches never read.
    private func seedSurfableFavorites() {
        let context = ModelContext(store.container)
        context.autosaveEnabled = false
        for playlist in [playlistID!, otherPlaylistID!] {
            let scope = "\(playlist.uuidString)-"
            autoreleasepool {
                for index in 0 ..< surfChannelCount {
                    let stream = LiveStream(
                        id: "\(scope)live-surf\(index)",
                        streamId: 100_000 + index,
                        name: "Surf Channel \(index)",
                        num: 100_000 + index,
                        categoryId: "\(scope)live-catsurf"
                    )
                    stream.isFavorite = true
                    stream.favoriteOrder = index
                    context.insert(stream)
                }
            }
        }
        try? context.save()
    }

    /// The channel at `index` of the seeded favorites list, launched from
    /// Favorites — the scope rides on the media and is what the navigator surfs
    /// within.
    private func surfMedia(at index: Int, in context: ModelContext) throws -> PlayableMedia {
        let streamID = "\(prefix)live-surf\(index)"
        var streamDescriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == streamID })
        streamDescriptor.fetchLimit = 1
        let stream = try XCTUnwrap(context.fetch(streamDescriptor).first)

        let activeID = playlistID!
        var playlistDescriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == activeID })
        playlistDescriptor.fetchLimit = 1
        let playlist = try XCTUnwrap(context.fetch(playlistDescriptor).first)

        return try XCTUnwrap(PlayableMedia.from(stream: stream, playlist: playlist, scope: .favorites))
    }

    /// Episodes for both playlists — one long-running show each plus a bulk of
    /// ordinary ones — and the season finale the benchmark resolves from.
    ///
    /// Episodes are wired to their series *after* `insert`, never through the
    /// initializer: see `M3UEpisodeRelationshipBenchmarks` for the 5x this costs
    /// the other way round.
    private func seedEpisodes() throws -> PlayableMedia.ContentRef {
        let context = ModelContext(store.container)
        context.autosaveEnabled = false
        for playlist in [playlistID!, otherPlaylistID!] {
            let scope = "\(playlist.uuidString)-"
            var descriptor = FetchDescriptor<Series>(
                predicate: #Predicate { $0.id.starts(with: scope) },
                sortBy: [SortDescriptor(\Series.num)]
            )
            descriptor.fetchLimit = episodeShowCount
            for (showIndex, show) in try context.fetch(descriptor).enumerated() {
                let seasons = showIndex == 0 ? longRunSeasons : 1
                autoreleasepool {
                    for season in 1 ... seasons {
                        for number in 1 ... episodesPerShow {
                            let episode = Episode(
                                id: "\(show.id)-s\(season)e\(number)",
                                episodeId: "\(season)\(number)",
                                title: "Episode \(number)",
                                containerExtension: "mkv",
                                seasonNum: season,
                                episodeNum: number
                            )
                            context.insert(episode)
                            episode.series = show
                        }
                    }
                }
            }
        }
        try context.save()
        return .episode("\(prefix)series-0-s\(longRunSeasons / 2)e\(episodesPerShow)")
    }
}

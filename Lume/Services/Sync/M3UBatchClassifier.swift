//
//  M3UBatchClassifier.swift
//  Lume
//
//  Classification for one parsed m3u batch, on the producer side of the import.
//
//  Classification is the one part of the import that *could* run anywhere: it
//  reads nothing and writes nothing. `M3UClassifier.episodeToken` is a shared
//  `NSRegularExpression` (matching on one instance is documented thread-safe)
//  and `M3UIdentity.hash64` is pure FNV-1a, so an entry classifies identically
//  on any thread. It runs here, in the parse task, rather than on the sync
//  actor, which takes it off the writer's critical path.
//
//  It is deliberately NOT fanned across cores. Measured at 600k entries, a
//  `withTaskGroup` split into `activeProcessorCount` chunks reassembled by
//  index classified each batch 4.4x faster (`M3UClassify` 0.022 s -> 0.005 s)
//  and made the whole import 3.7 s *slower* (192.41 s against 188.76 s; two
//  parallel runs agreed to 0.045 s, so that gap is far outside the noise).
//  The cause is structural rather than fixable overhead: the SwiftData writer
//  is the critical path by roughly 5x, so every core handed to the producer is
//  a core taken from the writer, and the producer is parked on back-pressure
//  either way. Do not re-derive this — the numbers are in the baseline block of
//  `LumePerformanceTests/M3UColdImportBenchmarks.swift`. If a later change ever
//  makes the writer fast enough that the parse becomes the bottleneck, the
//  trade flips and it is worth measuring again.
//
//  Nothing here touches `M3UImportState` — that type is an unsynchronized
//  `final nonisolated class` owned by the consumer (C6).
//

import Foundation

// MARK: - Carrier

/// One episode entry plus the season/episode split that identified it. A
/// typealias carries no isolation of its own, so nothing to annotate here.
typealias M3UClassifiedEpisode = (
    M3UEntry, series: String, season: Int, episode: Int, title: String
)

/// One batch of entries split by classification.
///
/// Sendable by inference (an internal struct of `M3UEntry`s and `String`/`Int`
/// tuples), which is what lets it cross from the parse task to the writer.
nonisolated struct M3UClassifiedBatch {
    var live: [M3UEntry] = []
    var movies: [M3UEntry] = []
    var episodes: [M3UClassifiedEpisode] = []
}

// MARK: - Classifier

nonisolated enum M3UBatchClassifier {
    /// Splits `entries` into live / movies / episodes, in file order — `num` is
    /// assigned from that order on first insert and is what "Playlist order"
    /// sorts by (C4).
    ///
    /// Its own `autoreleasepool` because the ICU matcher autoreleases an
    /// `NSTextCheckingResult` per entry, and the producer's other pool is
    /// `M3UParser.parseStreaming`'s per-chunk one, which has already drained by
    /// the time a completed batch is handed over (C5).
    static func classify(_ entries: [M3UEntry]) -> M3UClassifiedBatch {
        autoreleasepool {
            var batch = M3UClassifiedBatch()
            for entry in entries {
                let classification = M3UClassifier.classification(of: entry)
                switch classification.kind {
                case .live: batch.live.append(entry)
                case .movie: batch.movies.append(entry)
                case let .episode(series, season, episode):
                    batch.episodes.append((entry, series, season, episode, classification.episodeTitle))
                }
            }
            return batch
        }
    }
}

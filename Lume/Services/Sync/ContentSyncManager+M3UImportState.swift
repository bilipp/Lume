//
//  ContentSyncManager+M3UImportState.swift
//  Lume
//
//  The mutable state the m3u import carries across batches, and the summary it
//  returns. Split out of ContentSyncManager+M3U.swift, which sits against
//  SwiftLint's file-length limit.
//

import Foundation
import OSLog

// MARK: - Import state

/// Mutable registries that live across import batches: which categories exist,
/// which series have been created, and running provider-order counters.
final nonisolated class M3UImportState {
    /// Ensured category unique-ids, keyed by "\(typeRaw)|\(groupName)".
    var knownCategories: Set<String> = []
    /// Next first-appearance sort order per category type.
    var categoryOrder: [String: Int] = [:]
    /// Next `num` to hand to a newly-inserted row of each kind.
    ///
    /// Seeded past the highest `num` this playlist already stores, and advanced
    /// only when a row is actually inserted. m3u `num` is the entry's position
    /// in the file, so re-assigning it on every sync dirties the whole tail
    /// after any provider reordering and the dirty check delivers nothing; but
    /// handing an insert the raw file position instead would *collide* with the
    /// row that already holds it (a channel prepended to the file would take
    /// `num` 0 alongside the existing `num` 0, leaving "Playlist order" to break
    /// the tie arbitrarily). Appending past the maximum keeps every `num`
    /// distinct. The accepted cost is that new content sorts at the end rather
    /// than at its file position, so playlist order drifts from the provider's
    /// file over a playlist's life.
    var liveNum = 0
    var movieNum = 0
    var seriesNum = 0

    var importedLive = 0
    var importedMovies = 0
    var importedEpisodes = 0

    /// Ids seen this sync, accumulated across batches so a post-import sweep can
    /// prune rows the file no longer contains, held as `M3UIdentity.hash64` of
    /// the id: a provider file carries ~1.5M episode ids too long for Swift's
    /// inline small-string form, so keeping the strings costs ~337 MB resident
    /// across the whole import and every sweep, against ~19-33 MB for the
    /// hashes. The sweep recomputes the hash from each stored id, so both sides
    /// must agree on one deterministic function — `M3UIdentity.hash64`, never
    /// `Hasher`, whose seed changes per process.
    var seenLiveIds: Set<UInt64> = []
    var seenMovieIds: Set<UInt64> = []
    var seenSeriesIds: Set<UInt64> = []
    var seenEpisodeIds: Set<UInt64> = []
    /// Category keys stay strings: 1,544 groups is too few to matter, and
    /// `pruneStaleCategories` filters them by type prefix.
    var seenCategoryKeys: Set<String> = []

    /// First error hit inside a batch; aborts the remaining batches.
    var firstError: Error?

    var totalImported: Int {
        importedLive + importedMovies + importedEpisodes
    }

    /// Records a cancellation, if the task carrying the import has one, and
    /// answers whether the caller should stop.
    ///
    /// The parser's `onBatch` is neither async nor throwing, so a cancellation
    /// travels the one channel a batch already has: `firstError`, which makes
    /// every remaining batch return immediately and the import rethrow after the
    /// parse. Batches already committed stay — the import is abandoned, never
    /// rolled back — and the caller runs no sweep, because the seen-sets name
    /// only the part of the file that was read.
    func noteCancellationIfNeeded() -> Bool {
        guard Task.isCancelled else { return false }
        firstError = CancellationError()
        let imported = totalImported
        Logger.database.info("m3u import cancelled after \(imported) item(s); committed batches kept, no prune")
        return true
    }
}

// MARK: - Summary

nonisolated struct M3UImportSummary {
    var liveCount = 0
    var movieCount = 0
    var episodeCount = 0
    var headerEPGURL: String?
}

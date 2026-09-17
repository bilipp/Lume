//
//  ContentSyncManager+M3UPrune.swift
//  Lume
//
//  The m3u import's post-import mark-and-sweep. Split from
//  ContentSyncManager+M3U.swift, which sits against SwiftLint's file-length
//  limit. The sweeps themselves live in ContentSyncManager+Prune.swift; this is
//  only the order they run in, the gate they are handed, and the point each
//  seen-set is released.
//

import Foundation
import SwiftData

extension ContentSyncManager {
    /// The post-import sweeps, one signpost each: at provider scale they are a
    /// multi-minute phase of their own and a single import number hides that.
    ///
    /// Every sweep goes through the guarded entry points, never `pruneStale*`
    /// directly. A total of zero means the download or parse produced nothing
    /// and nothing is swept at all; past that, the coverage gate is what stops a
    /// download cut mid-file — which parses into a perfectly valid short
    /// playlist — from deleting the rows its missing tail would have named.
    ///
    /// Each set is dropped as soon as its own sweep returns: they are only ever
    /// read once, and holding all five to the end of the last sweep is the peak
    /// this import is measured at.
    func pruneStaleM3URows(playlistId: UUID, state: M3UImportState) {
        let imported = state.totalImported
        Perf.measure(.m3uPruneLive) {
            pruneLiveStreams(playlistId: playlistId, seenHashes: state.seenLiveIds, importedCount: imported)
        }
        state.seenLiveIds = []
        Perf.measure(.m3uPruneMovies) {
            pruneMovies(playlistId: playlistId, seenHashes: state.seenMovieIds, importedCount: imported)
        }
        state.seenMovieIds = []
        Perf.measure(.m3uPruneEpisodes) {
            pruneEpisodes(playlistId: playlistId, seenHashes: state.seenEpisodeIds, importedCount: imported)
        }
        state.seenEpisodeIds = []
        Perf.measure(.m3uPruneSeries) {
            pruneSeries(playlistId: playlistId, seenHashes: state.seenSeriesIds, importedCount: imported)
        }
        state.seenSeriesIds = []
        Perf.measure(.m3uPruneCategories) {
            for type in CategoryType.allCases {
                let typePrefix = "\(type.rawValue)|"
                let seenApiIds = Set(
                    state.seenCategoryKeys
                        .filter { $0.hasPrefix(typePrefix) }
                        .map { String($0.dropFirst(typePrefix.count)) }
                )
                pruneCategories(
                    playlistId: playlistId, type: type, seenApiIds: seenApiIds, importedCount: imported
                )
            }
        }
        state.seenCategoryKeys = []
    }
}

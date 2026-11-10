//
//  PlaylistDeletion.swift
//  Lume
//
//  Deleting a `Playlist` cascade-removes its `Category` rows (and, in turn, a
//  `Series`' episodes and a `Movie`/`Series`' cast, which cascade from their
//  parents). But `Movie`, `Series` and `LiveStream` are tied to a playlist only
//  by an `id` prefixed with the playlist's UUID — there is no SwiftData
//  relationship to cascade through. Left alone they orphan in the store forever:
//  they bloat storage (Settings then shows far more data than the active
//  playlist holds) and the content indexer keeps resolving titles whose playlist
//  no longer exists.
//
//  This removes that orphaned catalog content alongside the playlist. The
//  playlist row is deleted on the caller's context; the content goes through
//  contexts of its own, saved as it goes, and reaches `@Query`-backed views as
//  those saves merge.
//

import Foundation
import OSLog
import SwiftData

/// `nonisolated` so it can run both on the main actor (the Settings deletion
/// buttons) and on the `CloudSyncEngine` actor's own background context (when a
/// sibling device's deletion arrives over iCloud) — both use the same cleanup.
nonisolated enum PlaylistDeletion {
    /// Deletes `playlist` and every catalog item it brought in. Categories,
    /// episodes and cast members cascade from their parents; movies, series and
    /// live streams are matched by their playlist-scoped id prefix and removed
    /// explicitly, and the now-orphaned EPG listings for the playlist's channels
    /// are pruned.
    static func delete(_ playlist: Playlist, in context: ModelContext) {
        let playlistID = playlist.id

        // Drop the playlist's auto-created EPG source so it isn't re-synced.
        EPGSourceReconciler.remove(playlistID: playlistID, in: context)
        context.delete(playlist)

        removeOrphanedContent(playlistID: playlistID, in: context)

        Logger.sync.info("Deleted playlist \(playlistID.uuidString) and its orphaned catalog content")
    }

    /// The bulk half of a playlist deletion: every catalog item the playlist
    /// brought in, matched by its playlist-scoped id prefix, plus the
    /// device-local sync bookkeeping keyed by its UUID. Split from
    /// `delete(_:in:)` so `CloudSyncEngine.deletePlaylist` can save the removal
    /// of the `Playlist` row itself first (the UI's `@Query`s drop it promptly)
    /// before this — potentially long — cleanup runs.
    static func removeOrphanedContent(playlistID: UUID, in context: ModelContext) {
        let prefix = playlistID.uuidString

        // The prune gate's skip counters, the m3u file fingerprint and the
        // WebDAV listing fingerprint live in UserDefaults, outside every
        // cascade, so nothing else ever collects them: they would leak for the
        // lifetime of the install on each deleted playlist.
        SweepSkipDefaults.removeAll(playlistId: playlistID)
        M3UDigestStore.remove(playlistId: playlistID)
        WebDAVDigestStore.remove(playlistId: playlistID)
        XtreamDigestStore.removeAll(playlistId: playlistID)
        // Remembered sports channel picks name a channel in this playlist; drop
        // them here so both deletion paths (Settings and the iCloud reconcile's
        // `CloudSyncEngine.deletePlaylist`, which funnels through this method)
        // leave no dangling pin.
        SportsChannelPicks().remove(playlistID: playlistID)

        // Deleted without holding the catalog in memory. The old sweep fetched
        // every movie, series and channel of the playlist into this context and
        // saved once: about 1.2 GB for 178k movie rows, far past what an Apple TV
        // allows. Everything is scoped by the playlist-prefixed id, which
        // `starts(with:)` turns into a range seek on the unique `id` index.
        //
        // Channels and guide listings have no relationships, so
        // `delete(model:where:)` removes them without materializing a row (300k
        // rows: 2.6 s and 19 MB), on a context of their own. Episodes can't go
        // this way: Core Data refuses a batch delete that has to nullify their
        // series inverse, so they cascade from the series pages below.
        let bulk = ModelContext(context.container)
        bulk.autosaveEnabled = false

        // Prune guide listings for channels no surviving playlist carries.
        // Processed in bounded batches so neither removed nor surviving channels
        // are materialized in unbounded sets.
        pruneOrphanedEPGListings(prefix: prefix, in: bulk)

        try? bulk.delete(model: LiveStream.self, where: #Predicate { $0.id.starts(with: prefix) })
        try? bulk.save()

        // Movies and series cascade to their cast (and series to their
        // episodes), which a predicate delete would orphan, so they go row by
        // row — a page at a time, each page on its own context and saved, so no
        // page outlives its own deletion.
        deletePaged(container: context.container, idOf: { (movie: Movie) in movie.id }, page: { cursor, limit in
            var descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate { $0.id.starts(with: prefix) && $0.id > cursor },
                sortBy: [SortDescriptor(\.id, comparator: .lexical)]
            )
            descriptor.fetchLimit = limit
            return descriptor
        })
        deletePaged(container: context.container, pageSize: 200, idOf: { (show: Series) in show.id }, page: { cursor, limit in
            var descriptor = FetchDescriptor<Series>(
                predicate: #Predicate { $0.id.starts(with: prefix) && $0.id > cursor },
                sortBy: [SortDescriptor(\.id, comparator: .lexical)]
            )
            descriptor.fetchLimit = limit
            return descriptor
        })
    }

    /// Prunes EPG listings that are orphaned when `playlistID`'s channels are removed.
    ///
    /// Evaluates removed channels and surviving references in bounded batches so
    /// libraries with tens of thousands of channels never materialize unbounded
    /// channel arrays or string sets in memory. If the playlist has no EPG channels,
    /// this returns immediately without touching surviving channels.
    private static func pruneOrphanedEPGListings(prefix: String, in context: ModelContext) {
        // Fast path: if this playlist has no channels with an EPG channel ID,
        // skip orphan lookup entirely.
        var checkDescriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.id.starts(with: prefix) && $0.epgChannelId != nil }
        )
        checkDescriptor.fetchLimit = 1
        checkDescriptor.propertiesToFetch = [\.id]
        guard (try? context.fetch(checkDescriptor))?.isEmpty == false else {
            return
        }

        // Keyset-page through the doomed playlist's channels in bounded batches.
        // Candidate EPG IDs and surviving channel queries are processed per page,
        // so resident memory stays strictly O(batchSize).
        let batchSize = 500
        var cursor = ""

        while true {
            var fetchedCount = 0
            autoreleasepool {
                var removedDescriptor = FetchDescriptor<LiveStream>(
                    predicate: #Predicate {
                        $0.id.starts(with: prefix) &&
                            $0.epgChannelId != nil &&
                            $0.id > cursor
                    },
                    sortBy: [SortDescriptor(\.id, comparator: .lexical)]
                )
                removedDescriptor.fetchLimit = batchSize
                removedDescriptor.propertiesToFetch = [\.id, \.epgChannelId]

                let removedChannels = (try? context.fetch(removedDescriptor)) ?? []
                fetchedCount = removedChannels.count
                if let last = removedChannels.last {
                    cursor = last.id
                }

                let candidates = Array(Set(removedChannels.compactMap(\.epgChannelId)))
                guard !candidates.isEmpty else { return }

                // Check which of these candidate EPG IDs are still referenced by
                // surviving channels from OTHER playlists.
                var survivingDescriptor = FetchDescriptor<LiveStream>(
                    predicate: #Predicate {
                        !$0.id.starts(with: prefix) &&
                            $0.epgChannelId != nil &&
                            candidates.contains($0.epgChannelId!)
                    }
                )
                survivingDescriptor.propertiesToFetch = [\.epgChannelId]
                let survivingChannels = (try? context.fetch(survivingDescriptor)) ?? []
                let survivingEPGIDs = Set(survivingChannels.compactMap(\.epgChannelId))

                // Delete listings only for IDs that no surviving channel references.
                let orphaned = candidates.filter { !survivingEPGIDs.contains($0) }
                if !orphaned.isEmpty {
                    try? context.delete(model: EPGListing.self, where: #Predicate { orphaned.contains($0.channelId) })
                }
            }

            if fetchedCount < batchSize {
                break
            }
        }
    }

    /// Deletes every row `page` selects, `pageSize` at a time, keyed on the last
    /// id seen. `page` must ask for `id > cursor` in lexical order — see
    /// `ContentSyncManager.sweepPaged` for why the default comparator skips
    /// rows. Deleting while paging is sound: every row a page removes sorts at
    /// or before the cursor.
    private static func deletePaged<T: PersistentModel>(
        container: ModelContainer,
        pageSize: Int = 2000,
        idOf: (T) -> String,
        page: (_ cursor: String, _ limit: Int) -> FetchDescriptor<T>
    ) {
        var cursor = ""
        while true {
            var fetched = 0
            autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let rows = (try? context.fetch(page(cursor, pageSize))) ?? []
                fetched = rows.count
                if let last = rows.last { cursor = idOf(last) }
                for row in rows {
                    context.delete(row)
                }
                if !rows.isEmpty { try? context.save() }
            }
            if fetched < pageSize { return }
        }
    }
}

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
//  This removes that orphaned catalog content alongside the playlist. Run it on
//  the same context the deletion happens on so `@Query`-backed views refresh.
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
        let prefix = playlist.id.uuidString

        // Scope each fetch to the playlist in SQLite via the playlist-prefixed
        // id (a UUID, which appears nowhere else, so a substring match is exact)
        // instead of hydrating the whole catalog into memory just to filter it —
        // on a large library that was a multi-table full dump per deletion.
        let movieDescriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.id.localizedStandardContains(prefix) }
        )
        for movie in (try? context.fetch(movieDescriptor)) ?? [] {
            context.delete(movie)
        }

        let seriesDescriptor = FetchDescriptor<Series>(
            predicate: #Predicate { $0.id.localizedStandardContains(prefix) }
        )
        for show in (try? context.fetch(seriesDescriptor)) ?? [] {
            context.delete(show)
        }

        // LiveStream is far smaller than the catalog and EPG tables, and the
        // shared-channel partition below is simplest (and a predicate scoping a
        // fetch on an optional via `?? ""` can't be expressed in SwiftData's SQL
        // anyway), so fetch the streams once and split in memory: the channels
        // this playlist brought in, and the ones still owned elsewhere — a
        // channel another playlist also carries keeps its guide listings.
        let streams = (try? context.fetch(FetchDescriptor<LiveStream>())) ?? []
        let removedChannelIDs = Set(
            streams.filter { $0.id.hasPrefix(prefix) }.compactMap(\.epgChannelId)
        )
        let survivingChannelIDs = Set(
            streams.filter { !$0.id.hasPrefix(prefix) }.compactMap(\.epgChannelId)
        )
        for stream in streams where stream.id.hasPrefix(prefix) {
            context.delete(stream)
        }

        // Drop the playlist's auto-created EPG source so it isn't re-synced.
        EPGSourceReconciler.remove(playlistID: playlist.id, in: context)

        context.delete(playlist)

        // Prune the guide listings for channels no surviving playlist carries.
        // Scoped by `channelId` (now indexed) so this seeks the orphaned rows
        // instead of hydrating the entire — potentially huge — guide table.
        let orphanedChannelIDs = Array(removedChannelIDs.subtracting(survivingChannelIDs))
        if !orphanedChannelIDs.isEmpty {
            let listingDescriptor = FetchDescriptor<EPGListing>(
                predicate: #Predicate { orphanedChannelIDs.contains($0.channelId) }
            )
            for listing in (try? context.fetch(listingDescriptor)) ?? [] {
                context.delete(listing)
            }
        }

        Logger.sync.info("Deleted playlist \(prefix) and its orphaned catalog content")
    }
}

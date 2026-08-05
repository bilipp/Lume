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
        let playlistID = playlist.id

        // Drop the playlist's auto-created EPG source so it isn't re-synced.
        EPGSourceReconciler.remove(playlistID: playlistID, in: context)
        context.delete(playlist)

        removeOrphanedContent(playlistID: playlistID, in: context)

        Logger.sync.info("Deleted playlist \(playlistID.uuidString) and its orphaned catalog content")
    }

    /// The bulk half of a playlist deletion: every catalog item the playlist
    /// brought in, matched by its playlist-scoped id prefix. Split from
    /// `delete(_:in:)` so `CloudSyncEngine.deletePlaylist` can save the removal
    /// of the `Playlist` row itself first (the UI's `@Query`s drop it promptly)
    /// before this — potentially long — cleanup runs.
    static func removeOrphanedContent(playlistID: UUID, in context: ModelContext) {
        let prefix = playlistID.uuidString

        // Scope each fetch to the playlist in SQLite via the playlist-prefixed
        // id instead of hydrating the whole catalog into memory just to filter
        // it — on a large library that was a multi-table full dump per deletion.
        // `starts(with:)` compiles to a range seek on the unique `id` index.
        let movieDescriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        )
        for movie in (try? context.fetch(movieDescriptor)) ?? [] {
            context.delete(movie)
        }

        let seriesDescriptor = FetchDescriptor<Series>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        )
        for show in (try? context.fetch(seriesDescriptor)) ?? [] {
            context.delete(show)
        }

        // Split the channels in SQLite too: the ones this playlist brought in
        // (deleted below), and the ones still owned elsewhere — a channel
        // another playlist also carries keeps its guide listings. The surviving
        // fetch only needs `epgChannelId`, so it skips full-row hydration.
        let removedDescriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        )
        let removedStreams = (try? context.fetch(removedDescriptor)) ?? []
        let removedChannelIDs = Set(removedStreams.compactMap(\.epgChannelId))

        var survivingDescriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { !$0.id.starts(with: prefix) }
        )
        survivingDescriptor.propertiesToFetch = [\.epgChannelId]
        let survivingChannelIDs = Set(
            ((try? context.fetch(survivingDescriptor)) ?? []).compactMap(\.epgChannelId)
        )

        for stream in removedStreams {
            context.delete(stream)
        }

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
    }
}

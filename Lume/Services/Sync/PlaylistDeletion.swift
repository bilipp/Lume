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

        let movies = (try? context.fetch(FetchDescriptor<Movie>())) ?? []
        for movie in movies where movie.id.hasPrefix(prefix) {
            context.delete(movie)
        }

        let series = (try? context.fetch(FetchDescriptor<Series>())) ?? []
        for show in series where show.id.hasPrefix(prefix) {
            context.delete(show)
        }

        // Capture the channel ids of the streams being removed so we can drop
        // their guide listings, then keep the ids still owned by other playlists
        // so a shared channel's EPG survives.
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

        context.delete(playlist)

        let orphanedChannelIDs = removedChannelIDs.subtracting(survivingChannelIDs)
        if !orphanedChannelIDs.isEmpty {
            let listings = (try? context.fetch(FetchDescriptor<EPGListing>())) ?? []
            for listing in listings where orphanedChannelIDs.contains(listing.channelId) {
                context.delete(listing)
            }
        }

        Logger.sync.info("Deleted playlist \(prefix) and its orphaned catalog content")
    }
}

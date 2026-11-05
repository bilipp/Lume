//
//  ContentSyncManager+DisabledContent.swift
//  Lume
//
//  A playlist can stop fetching movies, series or live TV
//  (`Playlist.disabledContent`). Each pipeline skips the phases of a disabled
//  kind; this is the other half, run once per sync whatever the source: the
//  rows an earlier sync brought in go, so the library matches the switch even
//  when it was flipped on another device and arrived through cloud sync.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    /// Removes every row, category and import fingerprint of each kind in
    /// `disabled` for `playlistId`. A no-op for an empty set, and cheap once
    /// the rows are gone: each sweep is a range seek that finds nothing.
    ///
    /// Not the guarded prunes: those keep a library when a payload looks
    /// truncated, which is exactly the "nothing fetched" shape a disabled kind
    /// has. Movies and series go through `PlaylistDeletion`'s paged deletes so
    /// cast and episodes cascade; live streams through its bulk delete, which
    /// also drops the guide listings no other playlist's channel needs.
    func removeDisabledContent(playlistId: UUID, disabled: Set<PlaylistTab>) {
        for kind in PlaylistTab.allCases where disabled.contains(kind) {
            switch kind {
            case .movies:
                PlaylistDeletion.removeMovies(playlistID: playlistId, container: modelContainer)
                XtreamDigestStore.remove(playlistId: playlistId, endpoint: .movies)
            case .series:
                PlaylistDeletion.removeSeries(playlistID: playlistId, container: modelContainer)
                XtreamDigestStore.remove(playlistId: playlistId, endpoint: .series)
            case .liveTV:
                PlaylistDeletion.removeLiveStreams(playlistID: playlistId, container: modelContainer)
                XtreamDigestStore.remove(playlistId: playlistId, endpoint: .live)
            }
            pruneStaleCategories(playlistId: playlistId, type: kind.categoryType, seenApiIds: [])
            Logger.database.info(
                "Removed \(kind.rawValue, privacy: .public) content of playlist \(playlistId.uuidString, privacy: .public): kind disabled"
            )
        }
    }
}

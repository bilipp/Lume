import Foundation
import SwiftData

// MARK: - Value extraction

/// Snapshots a catalog model or its cloud mirror into the plain `*Values` struct
/// the three-way merge compares. Split out of `CloudSyncEngine.swift` to keep
/// that file within the project's file-length limit.
///
/// Not `private`: profile operations in `CloudSyncEngine+Profiles.swift` reuse
/// these helpers (fetch / reset / apply / value extraction).
extension CloudSyncEngine {
    static func values(from playlist: Playlist) -> PlaylistConfigValues {
        PlaylistConfigValues(
            name: playlist.name,
            serverURL: playlist.serverURL,
            username: playlist.username,
            password: playlist.password,
            macAddress: playlist.macAddress ?? "",
            sourceTypeRaw: playlist.sourceTypeRaw,
            epgURL: playlist.epgURL,
            syncEnabled: playlist.syncEnabled
        )
    }

    static func values(from mirror: SyncedPlaylist) -> PlaylistConfigValues {
        PlaylistConfigValues(
            name: mirror.name,
            serverURL: mirror.serverURL,
            username: mirror.username,
            password: mirror.password,
            macAddress: mirror.macAddress,
            sourceTypeRaw: mirror.sourceTypeRaw,
            epgURL: mirror.epgURL,
            syncEnabled: mirror.syncEnabled
        )
    }

    static func values(from source: EPGSource) -> EPGSourceValues {
        EPGSourceValues(name: source.name, url: source.url, isEnabled: source.isEnabled)
    }

    static func values(from mirror: SyncedEPGSource) -> EPGSourceValues {
        EPGSourceValues(name: mirror.name, url: mirror.url, isEnabled: mirror.isEnabled)
    }

    static func values(from mirror: UserContentState) -> ContentStateValues {
        ContentStateValues(
            watchProgress: mirror.watchProgress,
            isWatched: mirror.isWatched,
            lastWatchedDate: mirror.lastWatchedDate,
            isFavorite: mirror.isFavorite,
            addedToWatchlistDate: mirror.addedToWatchlistDate,
            favoriteOrder: mirror.favoriteOrder,
            recommendationVoteRaw: mirror.recommendationVoteRaw,
            isHidden: mirror.isHidden,
            customOrder: mirror.customOrder
        )
    }
}

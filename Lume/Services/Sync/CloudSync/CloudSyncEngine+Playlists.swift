//
//  CloudSyncEngine+Playlists.swift
//  Lume
//
//  Writes a merged playlist config to its cloud mirror or to the local
//  catalog. Split out of `CloudSyncEngine.swift` to keep that file within the
//  project's file-length limit.
//

import Foundation
import SwiftData

// MARK: - Playlist mutations

extension CloudSyncEngine {
    func applyPlaylistToCloud(_ value: PlaylistConfigValues?, id: UUID, mirror: SyncedPlaylist?) {
        guard let value else {
            if let mirror { deletionLog.delete(mirror, in: cloudContext) }
            return
        }
        if let mirror {
            mirror.name = value.name
            mirror.serverURL = value.serverURL
            mirror.username = value.username
            mirror.password = value.password
            mirror.macAddress = value.macAddress
            mirror.sourceTypeRaw = value.sourceTypeRaw
            mirror.epgURL = value.epgURL
            mirror.syncEnabled = value.syncEnabled
            mirror.hiddenTabsRaw = value.hiddenTabsRaw
            mirror.disabledContentRaw = value.disabledContentRaw
            mirror.updatedAt = Date()
        } else {
            cloudContext.insert(SyncedPlaylist(
                id: id,
                name: value.name,
                serverURL: value.serverURL,
                username: value.username,
                password: value.password,
                macAddress: value.macAddress,
                sourceTypeRaw: value.sourceTypeRaw,
                epgURL: value.epgURL,
                syncEnabled: value.syncEnabled,
                hiddenTabsRaw: value.hiddenTabsRaw,
                disabledContentRaw: value.disabledContentRaw
            ))
        }
    }

    /// Returns true if a new local `Playlist` was created (it has no
    /// `lastSyncDate`, so the UI's auto-sync will fetch its catalog).
    func applyPlaylistToLocal(_ value: PlaylistConfigValues?, id: UUID, local: Playlist?) -> Bool {
        guard let value else {
            // Mirror the local-deletion path: remove the playlist's orphaned
            // catalog content too, not just the `Playlist` row.
            if let local { PlaylistDeletion.delete(local, in: catalogContext) }
            return false
        }
        if let local {
            local.name = value.name
            local.serverURL = value.serverURL
            local.username = value.username
            local.password = value.password
            local.macAddress = value.macAddress.isEmpty ? nil : value.macAddress
            local.sourceTypeRaw = value.sourceTypeRaw
            local.epgURL = value.epgURL
            local.syncEnabled = value.syncEnabled
            local.hiddenTabsRaw = value.hiddenTabsRaw
            local.disabledContentRaw = value.disabledContentRaw
            return false
        }
        let playlist = Playlist(name: value.name, serverURL: value.serverURL, username: value.username, password: value.password)
        playlist.id = id
        playlist.macAddress = value.macAddress.isEmpty ? nil : value.macAddress
        playlist.sourceTypeRaw = value.sourceTypeRaw
        playlist.epgURL = value.epgURL
        playlist.syncEnabled = value.syncEnabled
        playlist.hiddenTabsRaw = value.hiddenTabsRaw
        playlist.disabledContentRaw = value.disabledContentRaw
        catalogContext.insert(playlist)
        return true
    }
}

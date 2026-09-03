//
//  M3UDigestStore.swift
//  Lume
//
//  Where the m3u sync remembers the fingerprint of the playlist file it last
//  imported, so an unchanged re-download can skip the import and the sweeps.
//
//  Device-local by design, exactly like `SweepSkipDefaults`: the digest records
//  what *this* device has already written into *its* store. Mirroring it (on the
//  `Playlist` model or through `SyncedPlaylist`) would let one device's finished
//  import suppress another device's first one, leaving that device with an empty
//  catalog and no way back until the provider's file changed.
//
//  Being outside every SwiftData cascade, nothing collects these keys on its
//  own — `PlaylistDeletion` clears them, or each deleted playlist leaks one for
//  the lifetime of the install.
//

import Foundation

nonisolated enum M3UDigestStore {
    static func key(playlistId: UUID) -> String {
        "sync.m3uDigest.\(playlistId.uuidString)"
    }

    static func digest(playlistId: UUID) -> String? {
        UserDefaults.standard.string(forKey: key(playlistId: playlistId))
    }

    static func store(_ digest: String, playlistId: UUID) {
        UserDefaults.standard.set(digest, forKey: key(playlistId: playlistId))
    }

    static func remove(playlistId: UUID) {
        UserDefaults.standard.removeObject(forKey: key(playlistId: playlistId))
    }
}

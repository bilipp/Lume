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
    /// What the importer writes, versioned. A fingerprint says "this device has
    /// already imported these bytes" — but only as the importer understood them
    /// at the time. When the importer learns to read something new from the
    /// same file (catch-up attributes, say), an unchanged playlist would
    /// otherwise skip the import forever and never pick it up. Bump this
    /// whenever an import starts writing a column it did not write before:
    /// every stored fingerprint stops matching, and each playlist re-imports
    /// once.
    ///
    /// History: 1 — the original fingerprint. 2 — m3u catch-up columns
    /// (`tvArchive`, `catchupTypeRaw`, `catchupSource`).
    static let importerRevision = 2

    static func key(playlistId: UUID) -> String {
        "sync.m3uDigest.\(playlistId.uuidString)"
    }

    /// The fingerprint of the file this device last imported in full, or `nil`
    /// when there is none — or only one written by an older importer revision.
    static func digest(playlistId: UUID) -> String? {
        guard let stored = UserDefaults.standard.string(forKey: key(playlistId: playlistId)) else { return nil }
        let prefix = revisionPrefix
        guard stored.hasPrefix(prefix) else { return nil }
        return String(stored.dropFirst(prefix.count))
    }

    static func store(_ digest: String, playlistId: UUID) {
        UserDefaults.standard.set(revisionPrefix + digest, forKey: key(playlistId: playlistId))
    }

    /// Fingerprints written before revisions existed carry no prefix at all,
    /// so they never match either.
    private static var revisionPrefix: String {
        "r\(importerRevision):"
    }

    static func remove(playlistId: UUID) {
        UserDefaults.standard.removeObject(forKey: key(playlistId: playlistId))
    }
}

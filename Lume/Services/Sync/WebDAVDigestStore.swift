//
//  WebDAVDigestStore.swift
//  Lume
//
//  Where the WebDAV sync remembers the fingerprint of the share listing it last
//  imported, so an unchanged tree can skip the import and the sweeps.
//
//  Device-local by design, exactly like `M3UDigestStore` and `SweepSkipDefaults`
//  (and like `streamFormatRaw` or a channel's `customOrder`, which are also
//  deliberately kept out of the CloudKit mirror): the fingerprint records what
//  *this* device has already written into *its* store. Mirroring it would let
//  one device's finished import suppress another device's first one, leaving
//  that device with an empty catalog and no way back until a file on the share
//  happened to change.
//
//  Being outside every SwiftData cascade, nothing collects these keys on its
//  own — `PlaylistDeletion` clears them, or each deleted playlist leaks one for
//  the lifetime of the install.
//

import CryptoKit
import Foundation

nonisolated enum WebDAVDigestStore {
    static func key(playlistId: UUID) -> String {
        "sync.webdavDigest.\(playlistId.uuidString)"
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

/// The fingerprint itself: a SHA-256 over every media file the walk listed.
///
/// An m3u playlist is one file, so its digest is the digest of the bytes. A
/// share has no such artifact — only the listing the walk assembled — so the
/// hash is taken over the per-file signatures, sorted so a server that returns
/// a directory's children in a different order between syncs does not read as a
/// change.
nonisolated enum WebDAVListingFingerprint {
    /// A file's identity as far as the catalog is concerned. `etag`,
    /// `getcontentlength` and `getlastmodified` are all optional in WebDAV and
    /// several NAS front-ends serve only some of them; an absent property
    /// contributes an empty field rather than being dropped, so a server that
    /// *starts* serving etags reads as a change (re-import) instead of
    /// colliding with the old fingerprint.
    static func signature(for resource: WebDAVResource) -> String {
        let href = resource.url.absoluteString
        let etag = resource.etag ?? ""
        let length = resource.contentLength.map(String.init) ?? ""
        let modified = resource.lastModified.map { String($0.timeIntervalSince1970) } ?? ""
        return "\(href)|\(etag)|\(length)|\(modified)"
    }

    static func make(from signatures: [String]) -> String {
        var hasher = SHA256()
        // Scheme marker: v1 hashed only the listing, so a share whose files
        // never changed kept the per-subfolder categories v1 filed. v2 files
        // every entry under the share root instead — the marker makes a stored
        // v1 digest miss exactly once, triggering the one full re-import that
        // moves existing installs onto the new grouping.
        hasher.update(data: Data("webdav-listing/v2\n".utf8))
        for signature in signatures.sorted() {
            hasher.update(data: Data(signature.utf8))
            hasher.update(data: Data([0x0A]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

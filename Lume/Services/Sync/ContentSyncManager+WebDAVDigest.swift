//
//  ContentSyncManager+WebDAVDigest.swift
//  Lume
//
//  Skip-if-unchanged for the WebDAV pipeline.
//
//  Unlike the m3u path, where the downloaded file's digest is known *before*
//  anything is parsed, a share's fingerprint only exists once the walk has
//  visited every directory — there is no single artifact to hash up front. So
//  the walk is never skipped; what a match skips is the import and the sweeps
//  behind it, which is where a re-sync of an unchanged share spends its time in
//  SQLite.
//

import Foundation
import OSLog

extension ContentSyncManager {
    /// Whether the tree the walk just listed is identical — href, etag, size and
    /// modification date of every media file — to the one this device last
    /// imported in full, and so needs neither import nor sweep.
    ///
    /// Skipping the sweep is part of the deal: rows an earlier failed sync
    /// deleted stay dead until something on the share changes. That is
    /// accepted — the sweeps only ever delete what the listing does not name,
    /// and the listing is the same listing.
    ///
    /// Anything but a match clears the stored fingerprint before the import
    /// begins, so a run that dies partway leaves nothing behind that would let
    /// the next sync trust a half-written catalog.
    ///
    /// A false match freezes the catalog silently and is close to undiagnosable
    /// from a bug report, so the skip is logged at `notice` — persisted, and
    /// therefore carried by `DebugLogExporter`. Neither the share URL nor the
    /// credentials appear: the fingerprint is a hash and the playlist is named
    /// by its local UUID.
    func webdavImportIsRedundant(fingerprint: String, playlistId: UUID) -> Bool {
        guard !fingerprint.isEmpty, fingerprint == WebDAVDigestStore.digest(playlistId: playlistId) else {
            WebDAVDigestStore.remove(playlistId: playlistId)
            return false
        }

        let identifier = playlistId.uuidString
        let short = String(fingerprint.prefix(16))
        Logger.database.notice(
            "WebDAV share \(identifier, privacy: .public) unchanged (sha256 \(short, privacy: .public)): skipping import and prune"
        )
        return true
    }

    /// Records the fingerprint of a listing this device has now imported end to
    /// end.
    ///
    /// Only ever called after a walk that completed *and* an import that
    /// committed — a partial walk names only the part of the share it reached,
    /// and fingerprinting that would make the next sync skip an import the
    /// catalog never received.
    ///
    /// Not recorded while any sweep is still being held back by the coverage
    /// gate: that gate defers deletions to a later sync, and a fingerprint would
    /// keep every later sync from running — stranding the rows it was meant to
    /// eventually collect.
    ///
    /// Nor for an import that produced nothing. An empty share is what a
    /// misconfigured path or a half-mounted volume looks like, and
    /// fingerprinting it would turn every later retry into an instant no-op.
    func recordWebDAVFingerprint(_ fingerprint: String, playlistId: UUID, importedCount: Int) {
        guard !fingerprint.isEmpty, importedCount > 0, !SweepSkipDefaults.hasAny(playlistId: playlistId) else {
            return
        }
        WebDAVDigestStore.store(fingerprint, playlistId: playlistId)
    }

    /// Finishes a sync whose listing matched the last import's fingerprint: no
    /// classify, no upsert, no sweep.
    ///
    /// Nothing to re-read here, unlike the m3u skip — a file share carries no
    /// `url-tvg` header and `EPGSourceReconciler` never creates a source for a
    /// WebDAV playlist.
    func completeSkippedWebDAVSync(playlistId: UUID, fileCount: Int, progress: SyncProgress?) async {
        await progress?.update(detail: "\(fileCount) items", fraction: 1)
        await progress?.complete(.playlistImport)
        markPlaylistUpdated(playlistId)
    }
}

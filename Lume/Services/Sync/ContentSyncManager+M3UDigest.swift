//
//  ContentSyncManager+M3UDigest.swift
//  Lume
//
//  Skip-if-unchanged for the m3u pipeline. The download is irreducible — the
//  provider serves no ETag, no Last-Modified and no compression — but once the
//  file is on disk, hashing it costs a fraction of a second against the minutes
//  a full parse-classify-upsert of the same bytes takes.
//
//  Split from ContentSyncManager+M3U.swift, which sits against SwiftLint's
//  file-length limit.
//

import Foundation
import OSLog

extension ContentSyncManager {
    /// Whether the freshly downloaded playlist is byte-identical to the one this
    /// device last imported in full, and so needs neither import nor sweep.
    ///
    /// Skipping the sweep is part of the deal: rows that an earlier failed sync
    /// deleted stay dead until the provider's file changes. That is accepted —
    /// the sweeps only ever delete what the file does not name, and the file is
    /// the same file.
    ///
    /// Anything but a match clears the stored fingerprint before the import
    /// begins, so a run that dies partway leaves nothing behind that would let
    /// the next sync trust a half-written catalog.
    ///
    /// A false match freezes the catalog silently and is close to
    /// undiagnosable from a bug report, so the skip is logged at `notice` —
    /// persisted, and therefore carried by `DebugLogExporter` — and scrubbed on
    /// the way out: playlist URLs carry account credentials as query items.
    func m3uImportIsRedundant(digest: String?, playlistId: UUID) -> Bool {
        guard let digest, digest == M3UDigestStore.digest(playlistId: playlistId) else {
            M3UDigestStore.remove(playlistId: playlistId)
            return false
        }

        let message = LogRedaction.scrubURLs(
            in: "m3u playlist \(playlistId.uuidString) unchanged (sha256 \(digest.prefix(16))): skipping import and prune"
        )
        Logger.database.notice("\(message, privacy: .public)")
        return true
    }

    /// Records the fingerprint of a playlist file this device has now imported
    /// end to end.
    ///
    /// Not recorded while any sweep is still being held back by the coverage
    /// gate: that gate defers deletions to a later sync, and a fingerprint would
    /// keep every later sync from running — stranding the rows it was meant to
    /// eventually collect.
    ///
    /// Nor for an import that produced nothing. A header-only or empty file is
    /// what a provider outage looks like, and fingerprinting it would turn every
    /// later retry into an instant no-op — the silent freeze this whole path has
    /// to avoid.
    func recordM3UDigest(_ digest: String?, playlistId: UUID, importedCount: Int) {
        guard let digest, importedCount > 0, !SweepSkipDefaults.hasAny(playlistId: playlistId) else { return }
        M3UDigestStore.store(digest, playlistId: playlistId)
    }

    /// Finishes a sync whose downloaded file matched the last import's
    /// fingerprint: no parse, no upsert, no sweep.
    ///
    /// The one thing a skip still has to do is re-read the `#EXTM3U` header. The
    /// catalog is unchanged, but the *user's* guide URL may not be — clearing it
    /// has to be answered by the file's own `url-tvg` on the next sync, or the
    /// playlist would sit without a guide until the provider's bytes happen to
    /// change. Reading the header alone costs one chunk, not a parse.
    func completeSkippedM3USync(
        playlistId: UUID,
        fileURL: URL,
        storedEPGURL: String?,
        progress: SyncProgress?
    ) async {
        await progress?.start(.playlistImport)
        if storedEPGURL == nil, let discovered = M3UParser.readHeader(fileURL: fileURL)?.epgURL {
            persistDiscoveredEPGURL(discovered, playlistId: playlistId)
        }
        await progress?.complete(.playlistImport)
        markPlaylistUpdated(playlistId)
    }
}

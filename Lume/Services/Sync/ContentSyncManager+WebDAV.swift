//
//  ContentSyncManager+WebDAV.swift
//  Lume
//
//  The WebDAV sync pipeline: recursively PROPFIND-walk a collection of media
//  files and feed the resulting entries into the existing m3u import machinery,
//  so classification, batching, pruning and enrichment stay one code path.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    func performWebDAVSync(playlist: Playlist, playlistId: UUID, progress: SyncProgress?) async throws {
        let credentials = Self.credentials(for: playlist)
        guard let root = URL(string: playlist.serverURL), root.scheme != nil, root.host() != nil else {
            throw WebDAVError.invalidURL
        }

        // The share competes for the same connection allowance as an Xtream
        // phase and the EPG guide download (PR #139). The walk itself is
        // strictly sequential — one PROPFIND at a time — and `EPGSyncService`
        // already stands down while this playlist's `syncStatus` is `.syncing`;
        // this pays whatever gap a preceding content phase still owes.
        try await spaceContentPhaseRequests()

        await progress?.start(.directoryWalk)
        let walk = try await walkShare(root: root, credentials: credentials, progress: progress)
        await progress?.complete(.directoryWalk)
        await progress?.start(.playlistImport)

        if webdavImportIsRedundant(fingerprint: walk.fingerprint, playlistId: playlistId) {
            await completeSkippedWebDAVSync(
                playlistId: playlistId, fileCount: walk.entries.count, progress: progress
            )
            return
        }

        let state = M3UImportState()
        seedImportState(state, playlistId: playlistId)

        let channel = M3UBatchChannel(capacity: WebDAVWalkProducer.channelCapacity)
        async let fed: Void = WebDAVWalkProducer.feed(walk.entries, into: channel)
        await consumeM3UBatches(
            from: channel,
            playlistId: playlistId,
            state: state,
            totalBytes: walk.entries.count,
            progress: progress
        )
        await fed

        if let error = state.firstError {
            // A cancellation is rethrown as-is: `syncPlaylist` reads that as an
            // abort and parks the playlist idle, where a `databaseError` would
            // wedge it in `.error`.
            throw error is CancellationError ? error : SyncError.databaseError(error)
        }
        try Task.checkCancellation()

        pruneStaleM3URows(playlistId: playlistId, state: state)
        recordWebDAVFingerprint(walk.fingerprint, playlistId: playlistId, importedCount: state.totalImported)

        let imported = state.totalImported
        let movies = state.importedMovies
        let episodes = state.importedEpisodes
        Logger.database.info(
            "WebDAV import finished: \(movies, privacy: .public) movie(s), \(episodes, privacy: .public) episode(s)"
        )
        await progress?.update(detail: "\(imported) items", fraction: 1)
        await progress?.complete(.playlistImport)

        markPlaylistUpdated(playlistId)
    }

    /// The walk, plus the one gate on everything downstream of it: only a walk
    /// that visited every directory beneath the share knows which rows are
    /// genuinely gone, and only such a walk may be fingerprinted as imported. A
    /// partial walk that pruned would delete catalog rows along with the
    /// favorites and watch progress keyed to them, and propagate those
    /// deletions through the next iCloud reconcile.
    private func walkShare(
        root: URL,
        credentials: WebDAVCredentials?,
        progress: SyncProgress?
    ) async throws -> WebDAVWalkResult {
        let walk: WebDAVWalkResult
        do {
            walk = try await WebDAVWalkProducer.walk(
                root: root, credentials: credentials, client: webdavClient, progress: progress
            )
        } catch {
            let described = (error as? WebDAVError)?.logDescription ?? "walk failed"
            Logger.database.error(
                "WebDAV walk aborted (\(described, privacy: .public)); catalog untouched, no prune, no fingerprint"
            )
            throw error
        }
        guard walk.isComplete else {
            Logger.database.error("WebDAV walk incomplete; skipping import and prune")
            throw SyncError.networkError(WebDAVError.invalidResponse)
        }
        return walk
    }

    /// `nil` for an anonymous share: an empty username means no `Authorization`
    /// header at all, not an empty Basic credential (which some servers answer
    /// with a 403 rather than the 401 that would let the user fix it).
    private static func credentials(for playlist: Playlist) -> WebDAVCredentials? {
        let username = playlist.username
        guard !username.isEmpty else { return nil }
        return WebDAVCredentials(username: username, password: playlist.password)
    }
}

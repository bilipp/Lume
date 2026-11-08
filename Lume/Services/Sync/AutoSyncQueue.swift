//
//  AutoSyncQueue.swift
//  Lume
//
//  The playlists waiting to be auto-synced, run one at a time: in the blocking
//  progress cover, or behind the library for a Combined member that already
//  has content (`AutoSync.presentsCover`). `MainTabView` feeds it on launch,
//  switch and foreground; the library toolbar's Sync feeds it while Combined is
//  on screen.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class AutoSyncQueue {
    /// The playlist shown in the blocking progress cover. Auto-sync is
    /// presented (not silent) so the user sees progress and waits for it to
    /// finish — most importantly right after adding a playlist, when the app
    /// would otherwise look empty and broken.
    var coverPlaylist: Playlist?

    /// The Combined member refreshing behind the library.
    private(set) var backgroundPlaylist: Playlist?

    private var pending: [Playlist] = []

    /// Playlists already auto-synced (or attempted) this session, so the
    /// launch / switch / foreground triggers don't re-present the cover for one
    /// that's already been handled.
    private var attempted: Set<UUID> = []

    /// The scope the latest request was made for; a background sync finishing
    /// promotes the next playlist against it.
    private var isCombined = false

    /// UI tests seed a fake playlist; auto-sync would present a blocking cover
    /// that can never succeed against the stub server, so skip it there.
    private let isDisabled = CommandLine.arguments.contains("-ui-testing")

    /// Whether anything is queued, in the cover or refreshing in the background.
    var isBusy: Bool {
        coverPlaylist != nil || backgroundPlaylist != nil || !pending.isEmpty
    }

    /// Enqueues every due playlist and starts the first one — the playlists on
    /// screen, plus any the viewer just added (see `AutoSync.shouldSync`).
    /// Covers the never-synced first launch (where `lastSyncDate == nil` makes a
    /// playlist due) as well as periodic refreshes. Combined members queue in
    /// priority order and run one at a time, never all at once.
    func enqueueDue(_ candidates: [Playlist], scope: CatalogScope, frequency: SyncFrequency, context: ModelContext) {
        guard !isDisabled else { return }
        for playlist in candidates.inPriorityOrder(of: scope) where AutoSync.shouldSync(
            playlist.autoSyncCandidate(in: scope),
            frequency: frequency,
            alreadyStarted: attempted.contains(playlist.id)
        ) {
            attempted.insert(playlist.id)
            pending.append(playlist)
        }
        promoteNextIfIdle(scope: scope, context: context)
    }

    /// The library toolbar's Sync while Combined is on screen: the due members
    /// (or all of them when none is) through the same sequential queue.
    func enqueueManualMembers(scope: CatalogScope, playlists: [Playlist], frequency: SyncFrequency, context: ModelContext) {
        guard !isDisabled else { return }
        let queued = Set(pending.map(\.id))
            .union([coverPlaylist?.id, backgroundPlaylist?.id].compactMap(\.self))
        for playlist in AutoSync.manualMemberSyncs(playlists.members(of: scope), frequency: frequency)
            where !queued.contains(playlist.id)
        {
            attempted.insert(playlist.id)
            pending.append(playlist)
        }
        promoteNextIfIdle(scope: scope, context: context)
    }

    /// Starts the next queued playlist's sync when none is running. The
    /// `SyncProgressView` auto-starts the sync and dismisses itself on success;
    /// the cover's `onDismiss` calls back here to advance the queue, as does a
    /// finished background sync.
    func promoteNextIfIdle(scope: CatalogScope, context: ModelContext) {
        isCombined = scope.isCombined
        promoteNextIfIdle(context: context)
    }

    private func promoteNextIfIdle(context: ModelContext) {
        guard coverPlaylist == nil, backgroundPlaylist == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        let presentsCover = AutoSync.presentsCover(
            isCombined: isCombined,
            hasContent: AutoSync.hasContent(next.id, in: context)
        )
        if presentsCover {
            coverPlaylist = next
        } else {
            backgroundPlaylist = next
            Task {
                await AutoSync.syncInBackground(next, container: context.container)
                backgroundPlaylist = nil
                promoteNextIfIdle(context: context)
            }
        }
    }
}

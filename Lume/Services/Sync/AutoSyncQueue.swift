//
//  AutoSyncQueue.swift
//  Lume
//
//  Every playlist sync the app runs, one at a time and always behind the
//  library: the automatic ones `MainTabView` feeds it on launch, switch and
//  foreground, and the manual ones from the library toolbar and a playlist's
//  settings. Nothing here takes the screen; the toolbar indicator, the empty
//  library placeholder and the activity sheet read `running` and `recent`.
//

import Foundation
import SwiftData

// MARK: - Job

/// One playlist sync, as the surfaces showing it see it. A value on purpose:
/// the playlist can be deleted while its sync is on screen.
struct SyncJob: Identifiable, Equatable {
    /// The playlist's id.
    let id: UUID
    let name: String
    let sourceType: PlaylistSourceType
    /// A Stalker full-catalog download rather than the default sync.
    let full: Bool
    /// Asked for by the viewer, rather than due on its own.
    let isManual: Bool
    /// The playlist has never finished a sync: this is its first import.
    let isFirstImport: Bool

    init(_ playlist: Playlist, full: Bool, isManual: Bool) {
        id = playlist.id
        name = playlist.name
        sourceType = playlist.sourceType
        self.full = full
        self.isManual = isManual
        isFirstImport = playlist.lastSyncDate == nil
    }

    var steps: [SyncStep] {
        SyncStep.steps(for: sourceType, full: full)
    }
}

/// The sync running right now and where it has got to.
struct RunningSync {
    let job: SyncJob
    let progress: SyncProgress
}

/// How the last sync ended. An aborted one leaves no trace.
struct FinishedSync {
    let job: SyncJob
    let progress: SyncProgress
    /// `nil` when it succeeded.
    let errorMessage: String?

    var failed: Bool {
        errorMessage != nil
    }
}

// MARK: - Queue

@MainActor
@Observable
final class AutoSyncQueue {
    private struct Entry {
        let job: SyncJob
        let playlist: Playlist
    }

    /// What runs one sync. `AutoSync.runSync` in the app; tests supply their own.
    typealias Runner = (_ playlist: Playlist, _ container: ModelContainer, _ progress: SyncProgress, _ full: Bool) async throws -> Void

    @ObservationIgnored private let run: Runner

    init(run: Runner? = nil) {
        self.run = run ?? { playlist, container, progress, full in
            try await AutoSync.runSync(playlist, container: container, progress: progress, full: full)
        }
    }

    private(set) var running: RunningSync?

    /// The sync that finished last, until another one finishes or the viewer
    /// has seen it (`acknowledgeRecent`).
    private(set) var recent: FinishedSync?

    /// The playlist `recent` was about, kept for Try Again.
    @ObservationIgnored private var recentPlaylist: Playlist?

    private var pending: [Entry] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var container: ModelContainer?

    /// Playlists already auto-synced (or attempted) this session, so the
    /// launch / switch / foreground triggers don't queue one twice.
    private var attempted: Set<UUID> = []

    /// UI tests seed a fake playlist; an automatic sync can never succeed
    /// against the stub server, so only manual ones run there.
    private let isAutomaticDisabled = CommandLine.arguments.contains("-ui-testing")

    /// Whether anything is queued or running.
    var isBusy: Bool {
        running != nil || !pending.isEmpty
    }

    /// The playlists waiting behind the running one, in order.
    var upNext: [SyncJob] {
        pending.map(\.job)
    }

    /// Whether one of `playlistIDs` is syncing or waiting to.
    func isSyncing(anyOf playlistIDs: Set<UUID>) -> Bool {
        if let running, playlistIDs.contains(running.job.id) { return true }
        return pending.contains { playlistIDs.contains($0.job.id) }
    }

    /// Whether `scope`'s one playlist is in its first import and `step`, the
    /// one that fills a tab, isn't done yet. That tab then shows the sync
    /// rather than category shells with nothing in them. Never in Combined,
    /// where the other members' rows are already there to browse.
    func isFirstImportAwaiting(_ step: SyncStep, in scope: CatalogScope) -> Bool {
        guard !scope.isCombined, let running, running.job.isFirstImport,
              scope.playlistIDs.contains(running.job.id) else { return false }
        return running.progress.isAwaiting(step)
    }

    /// The last sync's failure, while nothing is running and it belongs to one
    /// of `playlistIDs` (every playlist when `nil`).
    func recentFailure(in playlistIDs: Set<UUID>? = nil) -> FinishedSync? {
        guard running == nil, let recent, recent.failed else { return nil }
        if let playlistIDs, !playlistIDs.contains(recent.job.id) { return nil }
        return recent
    }

    // MARK: Enqueueing

    /// Enqueues every due playlist and starts the first one — the playlists on
    /// screen, plus any the viewer just added (see `AutoSync.shouldSync`).
    /// Covers the never-synced first launch (where `lastSyncDate == nil` makes a
    /// playlist due) as well as periodic refreshes. Combined members queue in
    /// priority order and run one at a time, never all at once.
    func enqueueDue(_ candidates: [Playlist], scope: CatalogScope, frequency: SyncFrequency, context: ModelContext) {
        guard !isAutomaticDisabled else { return }
        for playlist in candidates.inPriorityOrder(of: scope) where AutoSync.shouldSync(
            playlist.autoSyncCandidate(in: scope),
            frequency: frequency,
            alreadyStarted: attempted.contains(playlist.id)
        ) {
            attempted.insert(playlist.id)
            pending.append(Entry(job: SyncJob(playlist, full: false, isManual: false), playlist: playlist))
        }
        promoteNextIfIdle(container: context.container)
    }

    /// The library toolbar's Sync while Combined is on screen: the due members
    /// (or all of them when none is) through the same sequential queue.
    func enqueueManualMembers(scope: CatalogScope, playlists: [Playlist], frequency: SyncFrequency, context: ModelContext) {
        for playlist in AutoSync.manualMemberSyncs(playlists.members(of: scope), frequency: frequency)
            where !isQueued(playlist.id)
        {
            attempted.insert(playlist.id)
            pending.append(Entry(job: SyncJob(playlist, full: false, isManual: true), playlist: playlist))
        }
        promoteNextIfIdle(container: context.container)
    }

    /// The viewer's Sync for whatever is on screen: the due Combined members,
    /// or the one playlist. Does nothing while a sync is running or queued,
    /// and leaves a failed one for the activity screen to show, with its own
    /// Try Again.
    func syncOnScreenIfIdle(scope: CatalogScope, playlists: [Playlist], frequency: SyncFrequency, context: ModelContext) {
        guard !isBusy, recentFailure() == nil else { return }
        if scope.isCombined {
            enqueueManualMembers(scope: scope, playlists: playlists, frequency: frequency, context: context)
        } else if let playlist = playlists.primaryMember(of: scope) {
            sync(playlist, context: context)
        }
    }

    /// Sync Now for one playlist. It goes ahead of the automatic ones waiting,
    /// behind whatever is already running.
    func sync(_ playlist: Playlist, full: Bool = false, context: ModelContext) {
        if !isQueued(playlist.id) {
            attempted.insert(playlist.id)
            let entry = Entry(job: SyncJob(playlist, full: full, isManual: true), playlist: playlist)
            let firstAutomatic = pending.firstIndex { !$0.job.isManual } ?? pending.endIndex
            pending.insert(entry, at: firstAutomatic)
        }
        promoteNextIfIdle(container: context.container)
    }

    /// Runs the last failed sync again.
    func retryRecent(context: ModelContext) {
        guard recentFailure() != nil, let playlist = recentPlaylist else { return }
        let full = recent?.job.full ?? false
        clearRecent()
        sync(playlist, full: full, context: context)
    }

    // MARK: Stopping

    /// Aborts the running sync. `ContentSyncManager` restores the playlist to
    /// idle and keeps what was already imported; the queue then moves on.
    func stopRunning() {
        task?.cancel()
    }

    /// Drops the syncs of playlists that no longer exist.
    func dropSyncs(notIn playlistIDs: Set<UUID>) {
        pending.removeAll { !playlistIDs.contains($0.job.id) }
        if let running, !playlistIDs.contains(running.job.id) {
            stopRunning()
        }
        if let recent, !playlistIDs.contains(recent.job.id) {
            clearRecent()
        }
    }

    /// The viewer has seen how the last sync ended.
    func acknowledgeRecent() {
        if running == nil { clearRecent() }
    }

    private func clearRecent() {
        recent = nil
        recentPlaylist = nil
    }

    // MARK: Running

    private func isQueued(_ playlistID: UUID) -> Bool {
        running?.job.id == playlistID || pending.contains { $0.job.id == playlistID }
    }

    private func promoteNextIfIdle(container: ModelContainer) {
        self.container = container
        promoteNextIfIdle()
    }

    private func promoteNextIfIdle() {
        guard running == nil, !pending.isEmpty, let container else { return }
        let entry = pending.removeFirst()
        let progress = SyncProgress(steps: entry.job.steps)
        running = RunningSync(job: entry.job, progress: progress)

        let priority = AutoSync.taskPriority(
            isManual: entry.job.isManual,
            hasContent: AutoSync.hasContent(entry.job.id, in: container.mainContext)
        )
        task = Task(priority: priority) {
            var errorMessage: String?
            var wasStopped = false
            do {
                try await run(entry.playlist, container, progress, entry.job.full)
            } catch {
                // A cancelled network request surfaces as a non-CancellationError.
                if Task.isCancelled || error is CancellationError {
                    wasStopped = true
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            task = nil
            running = nil
            if !wasStopped {
                recent = FinishedSync(job: entry.job, progress: progress, errorMessage: errorMessage)
                recentPlaylist = entry.playlist
            }
            promoteNextIfIdle()
        }
    }
}

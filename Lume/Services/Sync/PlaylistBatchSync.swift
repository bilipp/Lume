//
//  PlaylistBatchSync.swift
//  Lume
//
//  One button that brings every playlist up to date. Auto-sync only refreshes
//  the playlist on screen (see `AutoSync.shouldSync`), so with several
//  playlists the rest drift until the viewer switches to each one, or opens
//  each one's detail pane and taps Sync Now.
//
//  This runs them without the blocking cover — that cover per playlist is what
//  auto-sync stopped doing at launch — and one at a time, because Xtream panels
//  commonly cap an account at one connection and playlists often share one.
//

import Foundation
import OSLog
import SwiftData

/// Which playlists the button syncs, and how it labels itself.
enum PlaylistBatchSelection: Equatable {
    /// Some playlists are stale; sync just those.
    case outOfDate([UUID])
    /// Everything is fresh. The button still does something rather than sit
    /// there disabled: it re-syncs every playlist that hasn't opted out.
    case all([UUID])
    /// Nothing eligible — every playlist is syncing or has sync turned off.
    case none

    var ids: [UUID] {
        switch self {
        case let .outOfDate(ids), let .all(ids): ids
        case .none: []
        }
    }

    /// Pure so it can be tested without a `ModelContext`. The active playlist
    /// goes first: it is the one the viewer is looking at.
    static func resolve(_ playlists: [(id: UUID, state: PlaylistSyncState, isActive: Bool)]) -> PlaylistBatchSelection {
        let ordered = playlists.filter(\.isActive) + playlists.filter { !$0.isActive }
        let stale = ordered.filter(\.state.isOutOfDate).map(\.id)
        if !stale.isEmpty { return .outOfDate(stale) }
        let eligible = ordered.filter { candidate in
            switch candidate.state {
            case .syncing, .disabled: false
            case .failed, .never, .overdue, .awaitingSelection, .synced: true
            }
        }
        return eligible.isEmpty ? .none : .all(eligible.map(\.id))
    }
}

extension PlaylistSyncState {
    /// Whether this playlist needs a sync. Overdue and awaiting-selection are
    /// the same staleness seen from the active and an inactive playlist, so
    /// both count; a failed sync left the old catalog in place but is still
    /// worth retrying. A playlist with sync turned off is skipped — that was a
    /// deliberate choice, and its detail pane's Sync Now still overrides it.
    var isOutOfDate: Bool {
        switch self {
        case .failed, .never, .overdue, .awaitingSelection: true
        case .syncing, .synced, .disabled: false
        }
    }
}

/// Runs a batch of playlist syncs in the background, one after another. Shared
/// so the run outlives the settings screen that started it.
@Observable
final class PlaylistBatchSync {
    static let shared = PlaylistBatchSync()

    /// How many playlists this run started with.
    private(set) var total = 0
    /// How many it has finished with, successfully or not.
    private(set) var finished = 0
    /// How many of those failed. The rows show which.
    private(set) var failures = 0
    private(set) var isRunning = false

    @ObservationIgnored private var task: Task<Void, Never>?

    /// The playlist being synced now, counting from 1.
    var position: Int {
        min(finished + 1, total)
    }

    /// Syncs the playlists `selection` names, in its order.
    func start(_ selection: PlaylistBatchSelection, from library: [Playlist], container: ModelContainer) {
        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let playlists = selection.ids.compactMap { byID[$0] }
        guard !isRunning, !playlists.isEmpty else { return }
        // A Sync All run picked playlists that were already fresh; only an
        // out-of-date run should drop one for having become fresh since.
        let onlyIfStale = if case .outOfDate = selection { true } else { false }
        total = playlists.count
        finished = 0
        failures = 0
        isRunning = true

        // To the guide refresh the whole batch is one content sync. Reporting
        // each playlist separately would let it slip in between two of them and
        // be cancelled again a second later by the next one.
        let epgSync = EPGSyncService.shared
        epgSync.contentSyncDidStart()
        task = Task {
            var anySucceeded = false
            defer {
                epgSync.contentSyncDidFinish(succeeded: anySucceeded)
                if anySucceeded { ContentIndexingService.shared.kick(after: .seconds(3)) }
                isRunning = false
                task = nil
            }
            let manager = ContentSyncManager(modelContainer: container)
            for playlist in playlists {
                if Task.isCancelled { break }
                // Checked again at its turn rather than trusted from when the
                // button was tapped: by now auto-sync may have run it (the
                // viewer switched to it), or it may be running in a cover.
                let state = playlist.syncState(isActive: false)
                if state == .syncing || (onlyIfStale && !state.isOutOfDate) {
                    finished += 1
                    continue
                }
                do {
                    try await BackgroundActivity.perform("Playlist sync") {
                        try await manager.syncPlaylist(playlist)
                    }
                    anySucceeded = true
                } catch {
                    if Task.isCancelled { break }
                    failures += 1
                    Logger.database.error("Batch sync: playlist \(playlist.id) failed — \(error)")
                }
                finished += 1
            }
        }
    }

    /// Stops after cancelling the playlist in flight, which `ContentSyncManager`
    /// puts back to idle rather than failed. The rest stay as they were.
    func cancel() {
        task?.cancel()
    }
}

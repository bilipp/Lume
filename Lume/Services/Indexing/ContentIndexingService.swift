//
//  ContentIndexingService.swift
//  Lume
//
//  Owns the background ContentIndexer task and publishes its status for the
//  Settings screen. Singleton because it must outlive any one view and be
//  reachable from the player (to pause indexing during playback) and from the
//  sync flow (to kick a pass after new content arrives).
//

import Foundation
import Observation
import OSLog
import SwiftData

@Observable
final class ContentIndexingService {
    static let shared = ContentIndexingService()

    enum State: Equatable {
        /// Not yet configured or never kicked.
        case idle
        /// Downloading/loading the embedding model.
        case preparing
        case indexing
        /// A playlist sync or playback is active; indexing resumes on its own.
        case waiting
        case upToDate
        /// The embedding model cannot be loaded on this device.
        case unavailable
        /// The last pass ended early (e.g. offline); the next kick retries.
        case interrupted
    }

    private(set) var state: State = .idle
    private(set) var indexedCount = 0
    private(set) var totalCount = 0

    /// Set by the player while the full-screen player is up. The indexer
    /// polls this and pauses: even background-context saves force a
    /// main-context merge that re-runs every @Query and hitches KSPlayer.
    var isPlaybackActive = false

    /// Set by `CloudSyncCoordinator` while `NSPersistentCloudKitContainer` is
    /// mid import/export. The indexer pauses then: CloudKit tears down and
    /// re-adds stores on the coordinator shared by the multi-store container,
    /// and faulting a catalog object during that window throws an uncatchable
    /// `no such table` `NSException`.
    var isCloudSyncActive = false

    private var container: ModelContainer?
    private var task: Task<Void, Never>?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    /// Starts a background indexing pass unless one is already running.
    /// Called on launch and after every successful playlist sync, so missing
    /// indexes are picked up without any user action.
    func kick() {
        guard let container, task == nil, state != .unavailable else { return }
        let indexer = ContentIndexer(modelContainer: container)
        task = Task {
            do {
                try await indexer.run(status: self)
            } catch is CancellationError {
                state = .interrupted
            } catch is TextEmbedder.EmbedderError {
                state = .unavailable
                Logger.indexing.error("Embedding model unavailable; content indexing disabled")
            } catch {
                state = .interrupted
                Logger.indexing.error("Indexing pass interrupted: \(error)")
            }
            task = nil
        }
    }

    // MARK: - Progress (called by ContentIndexer)

    func setPreparing() {
        state = .preparing
    }

    func setWaiting() {
        state = .waiting
    }

    func update(indexed: Int, total: Int) {
        indexedCount = indexed
        totalCount = total
        state = .indexing
    }

    func finish(indexed: Int, total: Int) {
        indexedCount = indexed
        totalCount = total
        state = .upToDate
    }
}

// MARK: - Settings status text

extension ContentIndexingService {
    /// One-line status for the Settings screen.
    var statusText: LocalizedStringResource {
        switch state {
        case .idle:
            "Not started"
        case .preparing:
            "Preparing…"
        case .indexing:
            "Indexed \(indexedCount) of \(totalCount) titles"
        case .waiting:
            "Paused"
        case .upToDate:
            totalCount > 0 ? "Up to date — \(totalCount) titles" : "Up to date"
        case .unavailable:
            "Not available on this device"
        case .interrupted:
            "Interrupted — will retry later"
        }
    }
}

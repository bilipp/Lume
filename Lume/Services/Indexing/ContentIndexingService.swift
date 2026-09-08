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
        /// A playlist sync, playback, an iCloud import or the user browsing is
        /// holding indexing off; it resumes on its own.
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

    /// When a browse surface last reported activity. The indexer pauses while
    /// this is recent, for the same reason it pauses for playback: the one
    /// `context.save()` that ends every chunk forces a main-context merge that
    /// re-runs every `@Query` in every mounted tab. On a 284k-row playlist that
    /// is ~4,500 whole-app query storms spread through ordinary use — measured,
    /// a single launch re-ran each of Home's six `@Query` properties 20-25
    /// times, and one "Add to Favorites" tap landed in a window holding 23,991
    /// fetches. Nobody is waiting on the index; the person scrolling is.
    ///
    /// Deliberately `@ObservationIgnored`: a stamp taken on every scroll that
    /// invalidated the views reading it would cost more than the indexer does.
    @ObservationIgnored private var lastUserInteraction: Date?

    /// How long a stamp keeps counting as "the user is here". Long enough to
    /// bridge the gaps between taps while paging through a catalog, short
    /// enough that a screen left open doesn't stall indexing for good.
    private static let browsingQuietWindow: TimeInterval = 8

    /// True while the user was interacting within the last
    /// `browsingQuietWindow` seconds. Self-clearing by construction: callers
    /// stamp and forget, so no view can leave indexing switched off by failing
    /// to unset a flag on the way out — the failure mode that a paired
    /// set/unset (like `isPlaybackActive`) has to be careful about.
    var isUserBrowsing: Bool {
        guard let lastUserInteraction else { return false }
        return Date.now.timeIntervalSince(lastUserInteraction) < Self.browsingQuietWindow
    }

    /// Called by browse surfaces to hold indexing off for the next few seconds.
    /// One line at the call site with nothing to balance, and it costs a single
    /// `Date` write — cheap enough to sit on an `.onAppear`, a tab change or a
    /// scroll/selection change.
    func noteUserInteraction() {
        lastUserInteraction = .now
    }

    private var container: ModelContainer?
    private var task: Task<Void, Never>?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    /// Starts a background indexing pass unless one is already running.
    /// Called on launch and after every successful playlist sync, so missing
    /// indexes are picked up without any user action.
    ///
    /// `delay` lets the post-sync caller hold the pass off briefly: a sync just
    /// grew the catalog and the user is about to browse it, so loading the
    /// embedding model and the per-chunk saves (each forces a main-context merge
    /// that re-runs every `@Query`) shouldn't fight that first browse. `task` is
    /// claimed immediately, so a second kick during the delay coalesces to a no-op.
    func kick(after delay: Duration = .zero) {
        guard let container, task == nil, state != .unavailable else { return }
        let indexer = ContentIndexer(modelContainer: container)
        task = Task {
            defer { task = nil }
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
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
        }
    }

    #if DEBUG
        /// DEBUG-only: cancels any in-flight pass and clears progress so the
        /// status reflects a freshly-wiped index. Pair with
        /// `StorageManager.clearIndex` then `kick()` to rebuild from scratch.
        func reset() {
            task?.cancel()
            task = nil
            if state != .unavailable {
                state = .idle
            }
            indexedCount = 0
            totalCount = 0
        }
    #endif

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

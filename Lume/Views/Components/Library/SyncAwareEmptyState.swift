//
//  SyncAwareEmptyState.swift
//  Lume
//
//  What an empty library surface shows while the playlist behind it is still
//  syncing, or after that sync failed, in place of its own "nothing here"
//  copy. Syncs run behind the library, so the first one meets empty tabs.
//

import SwiftData
import SwiftUI

struct SyncAwareEmptyState<Idle: View>: View {
    @Environment(AutoSyncQueue.self) private var queue: AutoSyncQueue?
    @Environment(\.catalogScope) private var catalogScope
    @Environment(\.modelContext) private var modelContext

    /// The surface's own empty state, shown when no sync explains the gap.
    @ViewBuilder var idle: Idle

    var body: some View {
        let playlistIDs = Set(catalogScope.playlistIDs)
        if let running = queue?.running, playlistIDs.contains(running.job.id) {
            LibrarySyncingPlaceholder(progress: running.progress)
        } else if queue?.isSyncing(anyOf: playlistIDs) == true {
            ContentUnavailableView {
                Label("Syncing Your Library", systemImage: "arrow.triangle.2.circlepath")
            } description: {
                Text("Waiting…")
            }
        } else if let failure = queue?.recentFailure(in: playlistIDs) {
            ContentUnavailableView {
                Label("Sync failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: failure.errorMessage ?? "")
            } actions: {
                Button("Try Again") {
                    queue?.retryRecent(context: modelContext)
                }
            }
        } else {
            idle
        }
    }
}

/// Its own view so the ring and the counts re-render alone, not the tab
/// around them, on every batch the import reports.
private struct LibrarySyncingPlaceholder: View {
    let progress: SyncProgress

    #if os(tvOS)
        private let ringSize: CGFloat = 132
        private let ringWidth: CGFloat = 10
    #else
        private let ringSize: CGFloat = 76
        private let ringWidth: CGFloat = 6
    #endif

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                SyncProgressRing(fraction: progress.overallFraction, lineWidth: ringWidth)
                    .foregroundStyle(ringStyle)
                progress.overallPercent
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: ringSize, height: ringSize)

            VStack(spacing: 6) {
                Text("Syncing Your Library")
                    .font(.title2.weight(.bold))
                SyncStepLine(progress: progress)
                    .foregroundStyle(.secondary)
            }

            Text("Titles appear here as they arrive.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var ringStyle: Color {
        #if os(tvOS)
            .white
        #else
            .accentColor
        #endif
    }
}

/// "Movies · 1200 of 4800": the running step and what it last reported.
struct SyncStepLine: View {
    let progress: SyncProgress

    var body: some View {
        if let step = progress.currentStep {
            let detail = progress.stepDetail
            if detail.isEmpty {
                Text(step.title)
            } else {
                Text(verbatim: "\(String(localized: step.title)) · \(detail)")
                    .monospacedDigit()
            }
        } else {
            Text("Syncing")
        }
    }
}

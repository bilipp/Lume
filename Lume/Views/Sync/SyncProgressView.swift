//
//  SyncProgressView.swift
//  Lume
//
//  Step-by-step progress UI for ContentSyncManager. Drives the sync, observes
//  SyncProgress, and renders each step's status, detail, and per-step progress.
//

import SwiftData
import SwiftUI

struct SyncProgressView: View {
    let playlist: Playlist
    @Binding var isPresented: Bool

    @Environment(\.modelContext) private var modelContext

    @State private var progress = SyncProgress()
    @State private var phase: Phase = .ready
    @State private var syncError: String?

    private enum Phase {
        case ready
        case syncing
        case finished
        case failed
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(SyncStep.allCases) { step in
                            StepRowView(
                                step: step,
                                state: progress.state(for: step),
                                detail: progress.currentStep == step ? progress.stepDetail : "",
                                fraction: progress.currentStep == step ? progress.stepFraction : 0
                            )
                        }
                    }
                    .padding()
                }

                Divider()

                footer
                    .padding()
            }
            .navigationTitle("Sync Playlist")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isPresented = false
                        }
                        .disabled(phase == .syncing)
                    }
                }
        }
        .interactiveDismissDisabled(phase == .syncing)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: headerIcon)
                    .font(.title2)
                    .foregroundStyle(headerTint)
                    .symbolEffect(.pulse, options: .repeating, isActive: phase == .syncing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.headline)
                    Text(playlist.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if phase == .syncing || phase == .finished {
                ProgressView(value: progress.overallFraction)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }
        }
        .padding()
    }

    private var headerIcon: String {
        switch phase {
        case .ready: "arrow.triangle.2.circlepath"
        case .syncing: "arrow.triangle.2.circlepath"
        case .finished: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var headerTint: Color {
        switch phase {
        case .ready, .syncing: .accentColor
        case .finished: .green
        case .failed: .red
        }
    }

    private var headerTitle: LocalizedStringKey {
        switch phase {
        case .ready: "Ready to sync"
        case .syncing: "Syncing your playlist"
        case .finished: "Sync complete"
        case .failed: "Sync failed"
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .ready:
            Button {
                startSync()
            } label: {
                Label("Start Sync", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .syncing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("This may take a few minutes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

        case .finished:
            Button {
                isPresented = false
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .failed:
            VStack(spacing: 12) {
                if let syncError {
                    Text(syncError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    startSync()
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Drive sync

    private func startSync() {
        // Fresh progress for each attempt so a retry starts clean.
        progress = SyncProgress()
        syncError = nil
        phase = .syncing

        Task {
            do {
                let syncManager = ContentSyncManager(modelContainer: modelContext.container)
                try await syncManager.syncPlaylist(playlist, progress: progress, full: true)
                await MainActor.run { phase = .finished }
            } catch {
                await MainActor.run {
                    syncError = error.localizedDescription
                    phase = .failed
                }
            }
        }
    }
}

// MARK: - Step Row

private struct StepRowView: View {
    let step: SyncStep
    let state: SyncStepState
    let detail: String
    let fraction: Double

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            statusIcon
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step.title)
                        .font(.subheadline)
                        .fontWeight(state == .active ? .semibold : .regular)
                        .foregroundStyle(titleColor)

                    Spacer()

                    if state == .active, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if state == .active, fraction > 0 {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.tertiary)
        case .active:
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 2)
                ProgressView()
                    .controlSize(.small)
            }
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var titleColor: Color {
        switch state {
        case .pending: .secondary
        case .active: .primary
        case .completed: .primary
        }
    }
}

#Preview("Ready") {
    let container = previewContainer()
    let playlist = PreviewData.samplePlaylist
    return SyncProgressView(playlist: playlist, isPresented: .constant(true))
        .modelContainer(container)
}

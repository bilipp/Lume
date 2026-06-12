//
//  SyncProgressView.swift
//  Lume
//
//  Step-by-step progress UI for ContentSyncManager. Drives the sync, observes
//  SyncProgress, and renders each step's status, detail, and per-step progress.
//
//  Two presentations share this view: the blocking auto-sync cover (autoStart)
//  and the manual "Sync Now" flow. iOS/macOS use a NavigationStack sheet; tvOS
//  uses a dedicated full-screen layout (`tvBody`) that matches the flat dark
//  settings surfaces — a plain sheet renders as a clipped centered card there.
//

import SwiftData
import SwiftUI

struct SyncProgressView: View {
    let playlist: Playlist

    /// When true the sync begins on appear and the sheet dismisses itself once
    /// it finishes successfully — used for the blocking auto-sync cover. When
    /// false (the manual "Sync Now" flow) it waits for the user to tap Start and
    /// shows a Done button when finished.
    let autoStart: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var progress = SyncProgress()
    @State private var phase: Phase
    @State private var syncError: String?

    init(playlist: Playlist, autoStart: Bool = false) {
        self.playlist = playlist
        self.autoStart = autoStart
        _progress = State(initialValue: SyncProgress(steps: SyncStep.steps(for: playlist.sourceType)))
        // Start already in the syncing state for auto-sync so the "Ready" screen
        // (with its Start button) never flashes before `.task` kicks off.
        _phase = State(initialValue: autoStart ? .syncing : .ready)
    }

    private enum Phase {
        case ready
        case syncing
        case finished
        case failed
    }

    var body: some View {
        #if os(tvOS)
            tvBody
        #else
            standardBody
        #endif
    }

    // MARK: - Shared header content

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

    // MARK: - Drive sync

    private func startSync() {
        // Fresh progress for each attempt so a retry starts clean.
        progress = SyncProgress(steps: SyncStep.steps(for: playlist.sourceType))
        syncError = nil
        phase = .syncing

        Task {
            do {
                let syncManager = ContentSyncManager(modelContainer: modelContext.container)
                try await syncManager.syncPlaylist(playlist, progress: progress, full: true)
                await MainActor.run {
                    // Newly synced titles need indexing; the launch-time pass
                    // may already be finished, so kick a fresh one.
                    ContentIndexingService.shared.kick()
                    phase = .finished
                    // Auto-sync gets out of the way as soon as it succeeds so the
                    // user can start browsing; the manual flow waits for Done.
                    if autoStart { dismiss() }
                }
            } catch {
                await MainActor.run {
                    syncError = error.localizedDescription
                    phase = .failed
                }
            }
        }
    }
}

// MARK: - iOS / macOS layout

#if !os(tvOS)

    private extension SyncProgressView {
        var standardBody: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    header

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(progress.steps) { step in
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
                                dismiss()
                            }
                            // Block dismissal while syncing — the user must wait for
                            // it to finish (or fail) before continuing.
                            .disabled(phase == .syncing)
                        }
                    }
            }
            .interactiveDismissDisabled(phase == .syncing)
            .task {
                if autoStart, phase != .finished {
                    startSync()
                }
            }
        }

        // MARK: Header

        var header: some View {
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

        // MARK: Footer

        @ViewBuilder
        var footer: some View {
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
                    dismiss()
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

                    // Let the user leave a failed auto-sync without retrying — they
                    // can sync later from the playlist's settings.
                    Button("Continue Without Syncing") {
                        dismiss()
                    }
                    .controlSize(.large)
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

#endif

// MARK: - tvOS layout

#if os(tvOS)

    private extension SyncProgressView {
        /// Full-screen, focusable layout sharing the flat dark fill used by the
        /// rest of the tvOS settings surfaces. Vertically centered — the eight
        /// steps plus header and footer comfortably fit a 1080p screen.
        var tvBody: some View {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 48) {
                    tvHeader
                    tvSteps
                    tvFooter
                }
                .frame(maxWidth: TVSettingsMetrics.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, 80)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tvSettingsBackground()
            .interactiveDismissDisabled(phase == .syncing)
            .task {
                if autoStart, phase != .finished {
                    startSync()
                }
            }
        }

        // MARK: Header

        var tvHeader: some View {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 28) {
                    Image(systemName: headerIcon)
                        .font(.system(size: 56))
                        .foregroundStyle(headerTint)
                        .symbolEffect(.pulse, options: .repeating, isActive: phase == .syncing)
                        .frame(width: 72)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(headerTitle)
                            .font(.system(size: 44, weight: .bold))
                        Text(verbatim: playlist.name)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                if phase == .syncing || phase == .finished {
                    ProgressView(value: progress.overallFraction)
                        .progressViewStyle(.linear)
                        .tint(.white)
                }
            }
        }

        // MARK: Steps

        var tvSteps: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(progress.steps) { step in
                    TVStepRow(
                        step: step,
                        state: progress.state(for: step),
                        detail: progress.currentStep == step ? progress.stepDetail : "",
                        fraction: progress.currentStep == step ? progress.stepFraction : 0
                    )
                }
            }
        }

        // MARK: Footer

        @ViewBuilder
        var tvFooter: some View {
            switch phase {
            case .ready:
                HStack(spacing: 24) {
                    Button {
                        startSync()
                    } label: {
                        Label("Start Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(TVSettingsActionButtonStyle(prominent: true))

                    Button("Cancel") { dismiss() }
                        .buttonStyle(TVSettingsActionButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .center)

            case .syncing:
                HStack(spacing: 16) {
                    ProgressView()
                    Text("This may take a few minutes…")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)

            case .finished:
                Button("Done") { dismiss() }
                    .buttonStyle(TVSettingsActionButtonStyle(prominent: true))
                    .frame(maxWidth: .infinity, alignment: .center)

            case .failed:
                VStack(spacing: 24) {
                    if let syncError {
                        Text(verbatim: syncError)
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 640)
                    }

                    HStack(spacing: 24) {
                        Button {
                            startSync()
                        } label: {
                            Label("Try Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(TVSettingsActionButtonStyle(prominent: true))

                        Button("Continue Without Syncing") { dismiss() }
                            .buttonStyle(TVSettingsActionButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - tvOS Step Row

    private struct TVStepRow: View {
        let step: SyncStep
        let state: SyncStepState
        let detail: String
        let fraction: Double

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 22) {
                    statusIcon
                        .frame(width: 40, height: 40)

                    Text(step.title)
                        .font(.system(size: 28, weight: state == .active ? .semibold : .regular))
                        .foregroundStyle(state == .pending ? .secondary : .primary)

                    Spacer(minLength: 16)

                    if state == .active, !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if state == .active, fraction > 0 {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .padding(.leading, 62)
                }
            }
            .padding(.vertical, 6)
        }

        @ViewBuilder
        private var statusIcon: some View {
            switch state {
            case .pending:
                Image(systemName: "circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
            case .active:
                ProgressView()
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }

#endif

#Preview("Ready") {
    let container = previewContainer()
    let playlist = PreviewData.samplePlaylist
    return SyncProgressView(playlist: playlist)
        .modelContainer(container)
}

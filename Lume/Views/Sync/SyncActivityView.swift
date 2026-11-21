//
//  SyncActivityView.swift
//  Lume
//
//  The playlist sync as a sheet: where the running one has got to, how the
//  last one ended, and what is waiting behind it. It only reports. The sync
//  belongs to `AutoSyncQueue` and keeps running when this is closed.
//
//  iOS, macOS and visionOS use the grouped form below; tvOS has its own
//  full-screen layout in `SyncActivityView+TV`.
//

import SwiftData
import SwiftUI

struct SyncActivityView: View {
    @Environment(AutoSyncQueue.self) var queue: AutoSyncQueue?
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Set where this is a tab rather than a presentation (tvOS): there is
    /// nothing to dismiss, so closing means leaving the tab.
    var onClose: (() -> Void)?

    /// What the sheet is showing. The running sync wins over the last result.
    enum Phase: Equatable {
        case syncing
        case finished
        case failed(String)
        case idle
    }

    var phase: Phase {
        if queue?.running != nil { return .syncing }
        guard let recent = queue?.recent else { return .idle }
        return recent.errorMessage.map(Phase.failed) ?? .finished
    }

    var job: SyncJob? {
        queue?.running?.job ?? queue?.recent?.job
    }

    var progress: SyncProgress? {
        queue?.running?.progress ?? queue?.recent?.progress
    }

    var body: some View {
        content
            .onDisappear { queue?.acknowledgeRecent() }
    }

    func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    func stopSync() {
        queue?.stopRunning()
        close()
    }

    func retry() {
        queue?.retryRecent(context: modelContext)
    }
}

// MARK: - Header

/// The ring, the playlist and one line on what is happening. Its own view so
/// the per-batch progress writes re-render it alone.
struct SyncActivityHeader: View {
    let phase: SyncActivityView.Phase
    let job: SyncJob?
    let progress: SyncProgress?
    var ringSize: CGFloat = 64
    var ringWidth: CGFloat = 6
    /// Ring beside the text, for a sheet; stacked and centred on tvOS.
    var isCompact = true

    var body: some View {
        let layout = isCompact ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 28))
        layout {
            ZStack {
                SyncProgressRing(fraction: ringFraction, lineWidth: ringWidth)
                    .foregroundStyle(tint)
                centre
            }
            .frame(width: ringSize, height: ringSize)

            VStack(alignment: isCompact ? .leading : .center, spacing: 4) {
                if let job {
                    Text(verbatim: job.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                }
                statusLine
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(isCompact ? .leading : .center)
            .frame(maxWidth: isCompact ? .infinity : nil, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var ringFraction: Double {
        switch phase {
        case .syncing: progress?.overallFraction ?? 0
        case .finished, .failed, .idle: 1
        }
    }

    @ViewBuilder
    private var centre: some View {
        switch phase {
        case .syncing:
            if let progress {
                progress.overallPercent
                    .font(.system(size: ringSize * 0.25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        case .finished, .idle:
            Image(systemName: "checkmark")
                .font(.system(size: ringSize * 0.38, weight: .bold))
                .foregroundStyle(tint)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: ringSize * 0.38, weight: .bold))
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch phase {
        case .syncing:
            if let progress {
                SyncStepLine(progress: progress)
            }
        case .finished: Text("Sync complete")
        case .failed: Text("Sync failed")
        case .idle: Text("Up to date")
        }
    }

    private var tint: Color {
        switch phase {
        case .syncing:
            #if os(tvOS)
                .white
            #else
                .accentColor
            #endif
        case .finished, .idle: .green
        case .failed: .orange
        }
    }
}

// MARK: - iOS / macOS / visionOS

#if !os(tvOS)

    extension SyncActivityView {
        var content: some View {
            NavigationStack {
                Form {
                    Section {
                        SyncActivityHeader(phase: phase, job: job, progress: progress)
                            .animation(.snappy, value: phase)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    if let progress {
                        Section {
                            ForEach(progress.steps) { step in
                                SyncStepRow(step: step, progress: progress)
                            }
                        }
                    }

                    if let upNext = queue?.upNext, !upNext.isEmpty {
                        Section("Up Next") {
                            ForEach(upNext) { job in
                                Label {
                                    Text(verbatim: job.name)
                                } icon: {
                                    Image(systemName: "clock")
                                }
                            }
                        }
                    }

                    actions
                }
                .formStyle(.grouped)
                .navigationTitle("Sync")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 520)
            #endif
        }

        @ViewBuilder
        private var actions: some View {
            switch phase {
            case .syncing:
                Section {
                    Button("Stop Sync", role: .destructive) { stopSync() }
                } footer: {
                    Text("You can keep using Lume while your playlist syncs.")
                }
            case let .failed(message):
                Section {
                    Button {
                        retry()
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                } footer: {
                    Text(verbatim: message)
                }
            case .finished, .idle:
                EmptyView()
            }
        }
    }

    /// One step of the pipeline: what it is, what it last reported, and
    /// whether it is waiting, running or done.
    private struct SyncStepRow: View {
        let step: SyncStep
        let progress: SyncProgress

        var body: some View {
            let state = progress.state(for: step)
            HStack(spacing: 12) {
                Label {
                    Text(step.title)
                } icon: {
                    Image(systemName: step.systemImage)
                }
                .foregroundStyle(state == .pending ? .secondary : .primary)

                Spacer(minLength: 8)

                Text(verbatim: progress.detail(for: step))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())

                status(state)
                    .frame(width: 22)
            }
            .accessibilityElement(children: .combine)
        }

        @ViewBuilder
        private func status(_ state: SyncStepState) -> some View {
            switch state {
            case .pending:
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
            case .active:
                ProgressView()
                    .controlSize(.small)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

#endif

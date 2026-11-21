//
//  SyncActivityView+TV.swift
//  Lume
//
//  The tvOS sync activity screen: the ring and the actions on the left, the
//  steps on the right, on the flat dark fill the settings surfaces share. A
//  plain sheet renders as a clipped centred card there.
//

#if os(tvOS)

    import SwiftUI

    extension SyncActivityView {
        var content: some View {
            HStack(alignment: .center, spacing: 96) {
                VStack(spacing: 44) {
                    SyncActivityHeader(phase: phase, job: job, progress: progress, ringSize: 220, ringWidth: 16, isCompact: false)
                        .animation(.snappy, value: phase)
                    tvActions
                }
                .frame(width: TVSettingsMetrics.sideColumnWidth)

                VStack(alignment: .leading, spacing: 36) {
                    if let progress {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(progress.steps) { step in
                                TVSyncStepRow(step: step, progress: progress)
                            }
                        }
                    }

                    if let upNext = queue?.upNext, !upNext.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            TVSettingsSectionLabel("Up Next")
                            ForEach(upNext) { job in
                                Text(verbatim: job.name)
                                    .font(.system(size: 26))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                            }
                        }
                    }
                }
                .frame(maxWidth: TVSettingsMetrics.contentMaxWidth, alignment: .leading)
            }
            .padding(.horizontal, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tvSettingsBackground()
        }

        private var tvActions: some View {
            VStack(spacing: 18) {
                switch phase {
                case .syncing:
                    Button("Continue in Background") { dismiss() }
                        .buttonStyle(TVSettingsActionButtonStyle(prominent: true))
                    Button("Stop Sync") { stopSync() }
                        .buttonStyle(TVSettingsActionButtonStyle())
                case let .failed(message):
                    Text(verbatim: message)
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        retry()
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(TVSettingsActionButtonStyle(prominent: true))
                    Button("Close") { dismiss() }
                        .buttonStyle(TVSettingsActionButtonStyle())
                case .finished, .idle:
                    Button("Done") { dismiss() }
                        .buttonStyle(TVSettingsActionButtonStyle(prominent: true))
                }
            }
        }
    }

    private struct TVSyncStepRow: View {
        let step: SyncStep
        let progress: SyncProgress

        var body: some View {
            let state = progress.state(for: step)
            HStack(spacing: 22) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 26))
                    .frame(width: 44)

                Text(step.title)
                    .font(.system(size: 28, weight: state == .active ? .semibold : .regular))

                Spacer(minLength: 16)

                Text(verbatim: progress.detail(for: step))
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)

                status(state)
                    .frame(width: 40, height: 40)
            }
            .foregroundStyle(state == .pending ? .secondary : .primary)
            .padding(.vertical, 12)
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
        }

        @ViewBuilder
        private func status(_ state: SyncStepState) -> some View {
            switch state {
            case .pending:
                Image(systemName: "circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
            case .active:
                ProgressView()
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
            }
        }
    }

#endif

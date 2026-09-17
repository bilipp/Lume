//
//  DownloadLiveActivity.swift
//  LumeWidgets
//
//  Lock-screen banner + Dynamic Island for the background download queue.
//  Everything renders from the content state pushed by the app's
//  `DownloadManager`; tapping any surface deep-links to the downloads list.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct DownloadLiveActivity: Widget {
    private static let downloadsURL = URL(string: "lume://downloads")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadLockScreenView(state: context.state)
                .widgetURL(Self.downloadsURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DownloadGlyphView(state: context.state, size: 34)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DownloadTrailingView(state: context.state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        DownloadActivityCopy.headline(for: context.state)
                            .font(.headline)
                            .lineLimit(1)
                        if let caption = DownloadActivityCopy.caption(for: context.state) {
                            caption
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DownloadProgressView(state: context.state)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                DownloadGlyphView(state: context.state, size: 18)
            } compactTrailing: {
                DownloadTrailingView(state: context.state)
            } minimal: {
                DownloadGlyphView(state: context.state, size: 18)
            }
            .widgetURL(Self.downloadsURL)
        }
    }
}

/// The lock-screen / banner presentation.
private struct DownloadLockScreenView: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            DownloadGlyphView(state: state, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    DownloadActivityCopy.headline(for: state)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if !state.isFinished {
                        Text(DownloadActivityCopy.percent(state.fractionCompleted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                DownloadProgressView(state: state)
                if let caption = DownloadActivityCopy.caption(for: state) {
                    caption
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .activityBackgroundTint(Color.black.opacity(0.55))
        .activitySystemActionForegroundColor(.white)
    }
}

/// Determinate bar for the fronted download. Byte progress isn't linear in
/// time, so unlike the playback activity there is no self-ticking timer
/// interval to lean on — the bar only moves when the app pushes an update.
/// Hidden once the batch is done, where the summary line carries the outcome.
private struct DownloadProgressView: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        if !state.isFinished {
            ProgressView(value: min(max(state.fractionCompleted, 0), 1))
                .progressViewStyle(.linear)
                .tint(.white)
        }
    }
}

/// Percentage while transferring, outcome glyph once the batch is done. Doubles
/// as the Dynamic Island's compact trailing accessory, where it is the only
/// thing carrying progress.
private struct DownloadTrailingView: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        if state.isFinished {
            Image(systemName: state.completedCount > 0 ? "checkmark" : "exclamationmark.triangle.fill")
                .foregroundStyle(state.completedCount > 0 ? .green : .orange)
        } else {
            Text(DownloadActivityCopy.percent(state.fractionCompleted))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// Status glyph: transferring, all done, or nothing landed.
private struct DownloadGlyphView: View {
    let state: DownloadActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size))
            .foregroundStyle(tint)
            .symbolRenderingMode(.hierarchical)
    }

    private var symbolName: String {
        guard state.isFinished else { return "arrow.down.circle.fill" }
        return state.completedCount > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        guard state.isFinished else { return .white }
        return state.completedCount > 0 ? .green : .orange
    }
}

/// The activity's copy, shared by the lock screen and the Dynamic Island so the
/// two never drift apart.
private enum DownloadActivityCopy {
    static func percent(_ fraction: Double) -> String {
        min(max(fraction, 0), 1).formatted(.percent.precision(.fractionLength(0)))
    }

    /// Item title while transferring, batch outcome once it's done.
    static func headline(for state: DownloadActivityAttributes.ContentState) -> Text {
        guard state.isFinished else { return Text(state.title) }
        if state.completedCount == 0 {
            return state.failedCount == 1
                ? Text("Download Failed", comment: "Live Activity headline: the only download in the batch failed")
                : Text(
                    "\(state.failedCount) Downloads Failed",
                    comment: "Live Activity headline: every download in the batch failed"
                )
        }
        return state.completedCount == 1
            ? Text("Download Complete", comment: "Live Activity headline: a single download finished")
            : Text(
                "\(state.completedCount) Downloads Complete",
                comment: "Live Activity headline: several downloads finished"
            )
    }

    /// Speed / ETA plus what's still owed while transferring; the failure tally
    /// once the batch is done, when there is one worth mentioning.
    static func caption(for state: DownloadActivityAttributes.ContentState) -> Text? {
        if state.isFinished {
            guard state.failedCount > 0, state.completedCount > 0 else { return nil }
            return Text(
                "\(state.failedCount) failed",
                comment: "Live Activity caption: downloads that failed alongside ones that finished"
            )
        }
        let remaining = state.remainingCount > 1
            ? Text("+\(state.remainingCount - 1) more", comment: "Live Activity caption: further downloads behind the visible one")
            : nil
        switch (state.statsLine, remaining) {
        case let (.some(stats), .some(remaining)):
            return Text(verbatim: "\(stats) · ") + remaining
        case let (.some(stats), .none):
            return Text(stats)
        case let (.none, .some(remaining)):
            return remaining
        case (.none, .none):
            return nil
        }
    }
}

// MARK: - Previews

private extension DownloadActivityAttributes.ContentState {
    static let transferring = Self(
        title: "The Grand Budapest Hotel",
        fractionCompleted: 0.42,
        statsLine: "12.4 MB/s · 3 min",
        activeCount: 1,
        queuedCount: 0,
        completedCount: 0,
        failedCount: 0,
        isFinished: false
    )
    static let queued = Self(
        title: "Severance S2E5",
        fractionCompleted: 0.78,
        statsLine: "3.2 MB/s · 40 sec",
        activeCount: 2,
        queuedCount: 4,
        completedCount: 1,
        failedCount: 0,
        isFinished: false
    )
    static let finished = Self(
        title: "",
        fractionCompleted: 1,
        statsLine: nil,
        activeCount: 0,
        queuedCount: 0,
        completedCount: 6,
        failedCount: 1,
        isFinished: true
    )
}

#Preview("Lock Screen", as: .content, using: DownloadActivityAttributes(sessionID: "preview")) {
    DownloadLiveActivity()
} contentStates: {
    DownloadActivityAttributes.ContentState.transferring
    DownloadActivityAttributes.ContentState.queued
    DownloadActivityAttributes.ContentState.finished
}

#Preview("Dynamic Island", as: .dynamicIsland(.expanded), using: DownloadActivityAttributes(sessionID: "preview")) {
    DownloadLiveActivity()
} contentStates: {
    DownloadActivityAttributes.ContentState.transferring
    DownloadActivityAttributes.ContentState.queued
    DownloadActivityAttributes.ContentState.finished
}

#Preview("Compact", as: .dynamicIsland(.compact), using: DownloadActivityAttributes(sessionID: "preview")) {
    DownloadLiveActivity()
} contentStates: {
    DownloadActivityAttributes.ContentState.transferring
    DownloadActivityAttributes.ContentState.finished
}

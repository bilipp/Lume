//
//  TVSyncStatusPill.swift
//  Lume
//
//  tvOS has no library toolbar to carry the sync indicator, so a running sync
//  shows as a small pill beside the tab bar. Never focusable: it reports, and
//  the sync is managed from the playlist's settings.
//

#if os(tvOS)

    import SwiftUI

    struct TVSyncStatusPill: View {
        let queue: AutoSyncQueue

        var body: some View {
            ZStack {
                if let running = queue.running {
                    Content(progress: running.progress)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: queue.running != nil)
            .allowsHitTesting(false)
        }

        private struct Content: View {
            let progress: SyncProgress

            var body: some View {
                HStack(spacing: 14) {
                    SyncProgressRing(fraction: progress.overallFraction, lineWidth: 4)
                        .frame(width: 30, height: 30)
                    Text("Syncing")
                    progress.overallPercent
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityElement(children: .combine)
            }
        }
    }

#endif

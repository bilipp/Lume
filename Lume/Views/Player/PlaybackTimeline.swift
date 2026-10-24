//
//  PlaybackTimeline.swift
//  Lume
//
//  The scrubber and time labels shared by the KSPlayer and LumeEngine
//  overlays and the casting remote.
//

import SwiftUI

#if !os(tvOS)

    /// The scrubber and time labels — the only part of a player surface that
    /// follows the 10 Hz playback clock. Isolated in its own view so each tick
    /// invalidates just this leaf: the controls above (menus, buttons) never
    /// re-render with it, which is what keeps an open track menu stable and
    /// tappable.
    struct PlaybackTimeline: View {
        var clock: PlaybackClock
        /// A recording still being captured: spans its growing playlist.
        let timeline: RecordingTimeline?
        @Binding var isSeeking: Bool
        @Binding var seekPosition: TimeInterval
        var onEditingChanged: (Bool) -> Void

        var body: some View {
            let duration = clock.displayDuration(growing: timeline)
            Slider(
                value: Binding<TimeInterval>(
                    get: { isSeeking ? seekPosition : (clock.current.isFinite ? clock.current : 0) },
                    set: { seekPosition = $0 }
                ),
                in: 0 ... max(duration.isFinite ? duration : 1, 1),
                onEditingChanged: onEditingChanged
            )
            .tint(.white)

            HStack {
                Text(timeString(from: isSeeking ? seekPosition : clock.current))
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                Spacer()
                Text(timeString(from: max(duration, 0)))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .font(.caption.monospacedDigit())
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        }

        private func timeString(from time: TimeInterval) -> String {
            guard time.isFinite, time >= 0 else { return "0:00" }
            let totalSeconds = Int(time)
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            let seconds = totalSeconds % 60
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, seconds)
            } else {
                return String(format: "%d:%02d", minutes, seconds)
            }
        }
    }

#endif

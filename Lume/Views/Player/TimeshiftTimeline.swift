#if os(macOS)
    import SwiftUI

    struct TimeshiftTimeline: View {
        let playback: TimeshiftPlayback
        let clock: PlaybackClock
        @State private var dragging = false
        @State private var target: TimeInterval = 0

        var body: some View {
            let position = playback.position(clock)
            VStack(spacing: 8) {
                Slider(value: Binding(get: { dragging ? target : position }, set: { target = $0 }),
                       in: playback.start ... max(playback.start + 0.01, playback.end))
                { editing in
                    if editing { target = position }
                    dragging = editing
                    if !editing { playback.seek(to: target) }
                }
                HStack {
                    let delay = max(0, playback.end - position)
                    Text(delay <= 5 ? "Live" : String(format: "−%d:%02d", Int(delay) / 60, Int(delay) % 60))
                        .monospacedDigit()
                    Spacer()
                    Button("Jump to Live") { playback.jumpToLive() }
                }
                if playback.expired {
                    Text("Older buffered content expired. Playback resumed at the earliest available point.")
                        .font(.caption)
                }
                if playback.interrupted {
                    Text("Live connection interrupted. Retained video is still available.")
                        .font(.caption)
                }
            }
        }
    }
#endif

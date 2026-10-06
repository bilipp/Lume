//
//  RecordingTimeline.swift
//  Lume
//
//  How far a recording that is still being captured reaches. The server
//  serves it as an HLS EVENT playlist without `#EXT-X-ENDLIST`, for which the
//  engines report no duration (KSPlayer: 0), so the overlays would pin the
//  scrubber's knob to the far end with a "0:00" total. This spans the scrubber
//  over the media captured so far instead, growing with the wall clock.
//

import Foundation
import LumeRecorderKit

nonisolated struct RecordingTimeline: Hashable, Codable {
    /// The captured length when the recording was last read from the server.
    let capturedDuration: TimeInterval
    /// When `capturedDuration` was current.
    let capturedAt: Date
    /// The scheduled end. Capture, and so the timeline's growth, stops there.
    let end: Date

    init(capturedDuration: TimeInterval, capturedAt: Date, end: Date) {
        self.capturedDuration = max(capturedDuration, 0)
        self.capturedAt = capturedAt
        self.end = end
    }

    /// The timeline of a recording still being captured; `nil` for any other
    /// status (a finished recording's playlist has `#EXT-X-ENDLIST`, so every
    /// engine reports its real duration). Prefers the server's measured media
    /// length; without one, the wall-clock time since capture started.
    init?(recording: Recording, at now: Date) {
        guard recording.status == .recording else { return nil }
        let measured = recording.durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let started = recording.startedAt ?? recording.start
        let elapsed = min(now, recording.end).timeIntervalSince(started)
        self.init(capturedDuration: measured ?? elapsed, capturedAt: now, end: recording.end)
    }

    /// The captured length at `now`: the known length plus the time since,
    /// up to the scheduled end.
    func duration(at now: Date) -> TimeInterval {
        capturedDuration + max(0, min(now, end).timeIntervalSince(capturedAt))
    }

    /// What a scrubber spans. Without a timeline that is the engine's duration,
    /// unchanged. For a growing recording it is the longer of the engine's
    /// duration (when it reports one) and the timeline, and never shorter than
    /// the position, so the knob can't run past the end.
    static func displayDuration(
        engineDuration: TimeInterval,
        position: TimeInterval,
        timeline: RecordingTimeline?,
        now: Date = .now
    ) -> TimeInterval {
        guard let timeline else { return engineDuration }
        let engine = engineDuration.isFinite ? max(engineDuration, 0) : 0
        let playhead = position.isFinite ? max(position, 0) : 0
        return max(engine, timeline.duration(at: now), playhead)
    }
}

extension PlaybackClock {
    /// `duration`, or for a recording still being captured, its growing
    /// timeline (see `RecordingTimeline.displayDuration`). Reads `current` and
    /// `duration`, so call it only where the clock is already followed.
    func displayDuration(growing timeline: RecordingTimeline?) -> TimeInterval {
        RecordingTimeline.displayDuration(engineDuration: duration, position: current, timeline: timeline)
    }
}

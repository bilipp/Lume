//
//  PlayableMedia+Recording.swift
//  Lume
//
//  Playback of a recording from the paired recording server. The grant URL is
//  path-signed and needs no headers, so every engine opens it as-is.
//

import Foundation
import LumeRecorderKit

nonisolated extension PlayableMedia {
    /// A recording, played as on-demand video from `grant`. `startTime` is the
    /// per-device resume point (see `RecordingProgressStore`). One still being
    /// captured carries its `RecordingTimeline` as of `now`.
    static func recording(
        _ recording: Recording,
        grant: PlaybackGrant,
        startTime: TimeInterval,
        now: Date = .now
    ) -> PlayableMedia {
        let identifier = RecordingProgressStore.identifier(for: recording.id)
        return PlayableMedia(
            id: "recording-\(identifier)",
            url: grant.url,
            title: recording.title,
            subtitle: recording.channelName,
            posterURL: recording.channelLogoURL,
            kind: .vod,
            startTime: startTime,
            contentRef: .recording(identifier),
            recordingTimeline: RecordingTimeline(recording: recording, at: now)
        )
    }

    /// The URL is short-lived (a recording's signed grant), so the media must
    /// never be persisted for a later reopen.
    var hasEphemeralURL: Bool {
        contentRef.isRecording
    }
}

nonisolated extension PlayableMedia.ContentRef {
    var isRecording: Bool {
        if case .recording = self { true } else { false }
    }
}

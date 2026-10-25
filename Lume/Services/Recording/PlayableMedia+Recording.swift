//
//  PlayableMedia+Recording.swift
//  Lume
//
//  Playback of a recording from the paired recording server, at the URL and
//  with the headers its backend hands out, and which engines can open it.
//

import Foundation

nonisolated extension PlayableMedia {
    /// A recording, played as on-demand video from `playback`. `startTime` is
    /// the per-device resume point (see `RecordingProgressStore`), keyed under
    /// `progressNamespace`. One still being captured carries its
    /// `RecordingTimeline` as of `now`.
    static func recording(
        _ recording: ServerRecording,
        playback: RecordingPlayback,
        progressNamespace: String? = nil,
        startTime: TimeInterval,
        now: Date = .now
    ) -> PlayableMedia {
        let identifier = RecordingProgressStore.identifier(for: recording.id, namespace: progressNamespace)
        return PlayableMedia(
            id: "recording-\(identifier)",
            url: playback.url,
            title: recording.title,
            subtitle: recording.channelName,
            posterURL: recording.channelLogoURL,
            kind: .vod,
            startTime: startTime,
            contentRef: .recording(identifier),
            httpHeaders: playback.httpHeaders.isEmpty ? nil : playback.httpHeaders,
            recordingTimeline: RecordingTimeline(recording: recording, at: now)
        )
    }

    /// The URL may be short-lived (a recording's signed grant) or need
    /// credential headers, so the media must never be persisted for a later
    /// reopen.
    var hasEphemeralURL: Bool {
        contentRef.isRecording
    }

    /// Engines that can't open this media. A Dispatcharr recording is MKV once
    /// finished, which AVPlayer can't demux (its in-progress HLS is unverified
    /// there too), and needs credential headers, which VLC can only send as
    /// the `?token=` JWT of a password sign-in.
    var unsupportedEngines: Set<PlayerEngineKind> {
        guard case let .recording(identifier) = contentRef,
              RecordingProgressStore.isDispatcharr(identifier)
        else { return [] }
        var engines: Set<PlayerEngineKind> = [.avPlayer]
        if DispatcharrPlaybackAuth.authenticatedURL(url, headers: httpHeaders) == nil {
            engines.insert(.vlcKit)
        }
        return engines
    }
}

nonisolated extension PlayableMedia.ContentRef {
    var isRecording: Bool {
        if case .recording = self { true } else { false }
    }
}

extension PlayerEnginePriority {
    /// `priority` without the engines `media` can't be opened by, so playback
    /// never starts on one of them and no engine fallback is spent skipping
    /// it. Unchanged when that would leave no engine at all.
    static func playable(_ priority: [PlayerEngineKind], for media: PlayableMedia) -> [PlayerEngineKind] {
        let unsupported = media.unsupportedEngines
        guard !unsupported.isEmpty else { return priority }
        let playable = priority.filter { !unsupported.contains($0) }
        return playable.isEmpty ? priority : playable
    }
}

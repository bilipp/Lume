import Foundation

/// The decisions behind `GoogleCastProvider`'s media half, on plain values so
/// they're testable without the Google Cast SDK: how a receiver media status
/// reduces to `CastPlaybackStatus`, when a new status is worth publishing,
/// and how a `CastMediaRequest` is described to the receiver.
nonisolated enum CastStatusMapping {
    /// `GCKMediaPlayerState`.
    enum PlayerState: Hashable {
        case unknown
        case idle
        case playing
        case paused
        case buffering
        case loading
    }

    /// `GCKMediaPlayerIdleReason`.
    enum ReceiverIdleReason: Hashable {
        case none
        case finished
        case cancelled
        case interrupted
        case error
    }

    /// `GCKMediaMetadataType`, limited to the types Lume sends.
    enum MetadataKind: Hashable {
        case movie
        case tvShow
        case generic
    }

    /// The fields of a `GCKMediaStatus` (and its media information) Lume reads.
    struct ReceiverStatus: Hashable {
        var playerState: PlayerState
        var idleReason: ReceiverIdleReason
        /// The client's approximate position, which advances between status
        /// messages while the receiver plays.
        var position: TimeInterval
        /// As the receiver reports it: live streams and unknown durations come
        /// back as infinity, NaN, zero or negative.
        var streamDuration: TimeInterval
        var isLive: Bool
        var title: String?
        var subtitle: String?
        var posterURL: URL?
    }

    /// How often the position moves forward while the receiver plays.
    static let positionUpdateInterval: TimeInterval = 1

    /// Slack for a ticker firing a hair early.
    private static let tickTolerance: TimeInterval = 0.1

    /// A position farther than this from where steady playback would put it
    /// is a seek, published at once.
    private static let jumpThreshold: TimeInterval = 2

    // MARK: - Status

    /// `receiver` reduced to Lume's status. `volume` is the device volume the
    /// session reports, which is what `setVolume` changes; the stream volume a
    /// media status carries isn't.
    static func status(from receiver: ReceiverStatus?, volume: Float) -> CastPlaybackStatus {
        var status = CastPlaybackStatus.idle
        status.volume = volume
        guard let receiver else { return status }

        switch receiver.playerState {
        case .unknown:
            return status
        case .idle:
            status.idleReason = idleReason(for: receiver.idleReason)
            return status
        case .playing:
            status.isPlaying = true
        case .paused:
            break
        case .buffering, .loading:
            status.isBuffering = true
        }
        status.hasMedia = true
        status.position = receiver.position.isFinite ? max(0, receiver.position) : 0
        status.duration = duration(receiver.streamDuration, isLive: receiver.isLive)
        status.title = receiver.title.flatMap(nonEmpty)
        status.subtitle = receiver.subtitle.flatMap(nonEmpty)
        status.posterURL = receiver.posterURL
        return status
    }

    /// Why an idle receiver stopped, or `nil` when it simply has nothing
    /// loaded yet.
    static func idleReason(for reason: ReceiverIdleReason) -> CastPlaybackStatus.IdleReason? {
        switch reason {
        case .none: nil
        case .finished: .finished
        case .cancelled: .stopped
        case .interrupted: .interrupted
        case .error: .error
        }
    }

    /// The item's length, or `nil` for a live stream or one the receiver
    /// can't measure yet.
    static func duration(_ streamDuration: TimeInterval, isLive: Bool) -> TimeInterval? {
        guard !isLive, streamDuration.isFinite, streamDuration > 0 else { return nil }
        return streamDuration
    }

    // MARK: - Throttle

    /// Whether `new` should replace the published `old`. Anything but the
    /// position goes out at once; steady playback advances the position at
    /// most once per `positionUpdateInterval`, while a seek — any move while
    /// not playing, or a jump during playback — goes out at once.
    static func shouldPublish(
        _ new: CastPlaybackStatus,
        over old: CastPlaybackStatus,
        lastPublishedAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        var oldAtNewPosition = old
        oldAtNewPosition.position = new.position
        if oldAtNewPosition != new { return true }
        guard new.position != old.position else { return false }
        guard new.isPlaying, let lastPublishedAt else { return true }

        let elapsed = now - lastPublishedAt
        if abs(new.position - old.position - elapsed) > jumpThreshold { return true }
        return elapsed >= positionUpdateInterval - tickTolerance
    }

    // MARK: - Load

    static func metadataKind(for contentRef: PlayableMedia.ContentRef) -> MetadataKind {
        switch contentRef {
        case .movie: .movie
        case .episode: .tvShow
        case .live, .recording: .generic
        }
    }

    /// Where the receiver starts, or `nil` to leave it to the receiver: a
    /// live stream then joins at the live edge, where an explicit 0 would put
    /// it at the start of the stream's DVR window.
    static func loadStartTime(for request: CastMediaRequest) -> TimeInterval? {
        request.streamType == .live ? nil : max(0, request.startTime)
    }

    private static func nonEmpty(_ string: String) -> String? {
        string.isEmpty ? nil : string
    }
}

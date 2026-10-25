import Foundation
@testable import Lume
import Testing

/// How a receiver media status becomes Lume's `CastPlaybackStatus`, when a new
/// status is published, and how a request is described to the receiver.
struct CastStatusMappingTests {
    private static func receiver(
        _ state: CastStatusMapping.PlayerState,
        idleReason: CastStatusMapping.ReceiverIdleReason = .none,
        position: TimeInterval = 42,
        streamDuration: TimeInterval = 3600,
        isLive: Bool = false
    ) -> CastStatusMapping.ReceiverStatus {
        CastStatusMapping.ReceiverStatus(
            playerState: state,
            idleReason: idleReason,
            position: position,
            streamDuration: streamDuration,
            isLive: isLive,
            title: "Title",
            subtitle: "Subtitle",
            posterURL: URL(string: "https://img.example.com/poster.jpg")
        )
    }

    private static func playing(at position: TimeInterval, isPlaying: Bool = true) -> CastPlaybackStatus {
        var status = CastPlaybackStatus.idle
        status.hasMedia = true
        status.isPlaying = isPlaying
        status.position = position
        status.duration = 3600
        return status
    }

    private static func request(
        streamType: CastMediaRequest.StreamType,
        startTime: TimeInterval
    ) -> CastMediaRequest {
        CastMediaRequest(
            contentURL: URL(fileURLWithPath: "/stream"),
            contentType: "video/mp4",
            streamType: streamType,
            title: "Title",
            subtitle: nil,
            posterURL: nil,
            startTime: startTime,
            contentRef: .movie("m1")
        )
    }

    // MARK: - Status

    @Test(arguments: [
        (CastStatusMapping.PlayerState.playing, true, false),
        (.paused, false, false),
        (.buffering, false, true),
        (.loading, false, true)
    ])
    func `an active player state carries media`(state: CastStatusMapping.PlayerState, isPlaying: Bool, isBuffering: Bool) {
        let status = CastStatusMapping.status(from: Self.receiver(state), volume: 0.4)

        #expect(status.hasMedia)
        #expect(status.isPlaying == isPlaying)
        #expect(status.isBuffering == isBuffering)
        #expect(status.idleReason == nil)
        #expect(status.position == 42)
        #expect(status.duration == 3600)
        #expect(status.volume == 0.4)
    }

    @Test(arguments: [
        (CastStatusMapping.ReceiverIdleReason.none, CastPlaybackStatus.IdleReason?.none),
        (.finished, .finished),
        (.cancelled, .stopped),
        (.interrupted, .interrupted),
        (.error, .error)
    ])
    func `an idle receiver maps its idle reason`(
        reason: CastStatusMapping.ReceiverIdleReason,
        expected: CastPlaybackStatus.IdleReason?
    ) {
        let status = CastStatusMapping.status(from: Self.receiver(.idle, idleReason: reason), volume: 1)

        #expect(!status.hasMedia)
        #expect(!status.isPlaying)
        #expect(status.idleReason == expected)
    }

    @Test func `an unknown state or a missing status is idle at the session volume`() {
        #expect(CastStatusMapping.status(from: Self.receiver(.unknown), volume: 0.3) == {
            var status = CastPlaybackStatus.idle
            status.volume = 0.3
            return status
        }())
        #expect(CastStatusMapping.status(from: nil, volume: 1) == .idle)
    }

    @Test func `the receiver's own metadata is kept for a resumed session`() {
        let status = CastStatusMapping.status(from: Self.receiver(.playing), volume: 1)

        #expect(status.title == "Title")
        #expect(status.subtitle == "Subtitle")
        #expect(status.posterURL == URL(string: "https://img.example.com/poster.jpg"))
    }

    @Test func `empty receiver metadata reads as missing`() {
        var receiver = Self.receiver(.playing)
        receiver.title = ""
        receiver.subtitle = ""

        let status = CastStatusMapping.status(from: receiver, volume: 1)

        #expect(status.title == nil)
        #expect(status.subtitle == nil)
    }

    @Test(arguments: [-5.0, .nan, .infinity])
    func `an unusable position reads as the start`(position: TimeInterval) {
        let status = CastStatusMapping.status(from: Self.receiver(.playing, position: position), volume: 1)
        #expect(status.position == 0)
    }

    @Test(arguments: [
        (3600.0, false, 3600 as TimeInterval?),
        (3600, true, nil),
        (.infinity, false, nil),
        (.nan, false, nil),
        (0, false, nil),
        (-1, false, nil)
    ])
    func `only a finite on-demand length is a duration`(raw: TimeInterval, isLive: Bool, expected: TimeInterval?) {
        #expect(CastStatusMapping.duration(raw, isLive: isLive) == expected)
    }

    // MARK: - Throttle

    @Test(arguments: [
        // Steady playback: at most one position step per second.
        (playing(at: 10), playing(at: 10.5), 100.0, 100.5, false),
        (playing(at: 10), playing(at: 11), 100, 101, true),
        (playing(at: 10), playing(at: 10.95), 100, 100.95, true),
        // A seek during playback goes out at once.
        (playing(at: 10), playing(at: 300), 100, 100.2, true),
        (playing(at: 300), playing(at: 10), 100, 100.2, true),
        // Any move while paused is a seek.
        (playing(at: 10, isPlaying: false), playing(at: 12, isPlaying: false), 100, 100.1, true),
        // Nothing moved.
        (playing(at: 10), playing(at: 10), 100, 105, false),
        // Anything but the position goes out at once.
        (playing(at: 10), playing(at: 10.2, isPlaying: false), 100, 100.2, true)
    ])
    func `position updates are throttled to about once a second`(
        old: CastPlaybackStatus,
        new: CastPlaybackStatus,
        lastPublishedAt: TimeInterval,
        now: TimeInterval,
        expected: Bool
    ) {
        #expect(CastStatusMapping.shouldPublish(new, over: old, lastPublishedAt: lastPublishedAt, now: now) == expected)
    }

    @Test func `the first status always goes out`() {
        #expect(CastStatusMapping.shouldPublish(Self.playing(at: 10), over: Self.playing(at: 9), lastPublishedAt: nil, now: 0))
    }

    @Test func `an idle reason goes out even when the position is unchanged`() {
        var finished = Self.playing(at: 10)
        finished.idleReason = .finished
        #expect(CastStatusMapping.shouldPublish(finished, over: Self.playing(at: 10), lastPublishedAt: 100, now: 100.1))
    }

    @Test func `a volume change goes out at once`() {
        var louder = Self.playing(at: 10.1)
        louder.volume = 0.5
        #expect(CastStatusMapping.shouldPublish(louder, over: Self.playing(at: 10), lastPublishedAt: 100, now: 100.1))
    }

    // MARK: - Load

    @Test(arguments: [
        (PlayableMedia.ContentRef.movie("m1"), CastStatusMapping.MetadataKind.movie),
        (.episode("e1"), .tvShow),
        (.live("l1"), .generic),
        (.recording("r1"), .generic)
    ])
    func `the metadata type follows the catalog item`(contentRef: PlayableMedia.ContentRef, kind: CastStatusMapping.MetadataKind) {
        #expect(CastStatusMapping.metadataKind(for: contentRef) == kind)
    }

    @Test(arguments: [
        (CastMediaRequest.StreamType.buffered, 754.0, 754 as TimeInterval?),
        (.buffered, 0, 0),
        (.live, 0, nil),
        (.live, 120, nil)
    ])
    func `live loads join at the live edge`(
        streamType: CastMediaRequest.StreamType,
        startTime: TimeInterval,
        expected: TimeInterval?
    ) {
        let request = Self.request(streamType: streamType, startTime: startTime)
        #expect(CastStatusMapping.loadStartTime(for: request) == expected)
    }
}

//
//  RecordingTimelineTests.swift
//  LumeTests
//
//  The scrubber span for a recording still being captured: its growing HLS
//  EVENT playlist reports no duration, so the overlays fall back to the
//  captured length, grown with the wall clock and never shorter than the
//  playhead. Finished recordings keep the engine's duration.
//

import Foundation
@testable import Lume
import LumeRecorderKit
import Testing

struct RecordingTimelineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRecording(
        status: RecordingStatus,
        startedAgo: TimeInterval? = 600,
        endsIn: TimeInterval = 1800,
        durationSeconds: Double? = nil
    ) -> Recording {
        Recording(
            id: UUID(), title: "Match", channelName: "Sports", channelLogoURL: nil, programmeDescription: nil,
            sourceRef: nil, start: now.addingTimeInterval(-900), end: now.addingTimeInterval(endsIn), status: status,
            failureReason: nil, createdAt: now.addingTimeInterval(-1000),
            startedAt: startedAgo.map { now.addingTimeInterval(-$0) }, finishedAt: nil,
            durationSeconds: durationSeconds, sizeBytes: nil
        )
    }

    private func makeGrant() throws -> PlaybackGrant {
        try PlaybackGrant(
            url: #require(URL(string: "http://192.168.1.20:8090/play/abc/1/sig/index.m3u8")),
            expiresAt: now.addingTimeInterval(3600)
        )
    }

    // MARK: - Building the timeline

    @Test func `only a recording still being captured has a timeline`() {
        #expect(RecordingTimeline(recording: makeRecording(status: .recording), at: now) != nil)
        for status in [RecordingStatus.completed, .failed, .cancelled, .scheduled] {
            #expect(RecordingTimeline(recording: makeRecording(status: status, durationSeconds: 120), at: now) == nil)
        }
    }

    @Test func `the server's measured length wins over the wall clock`() throws {
        let timeline = try #require(RecordingTimeline(recording: makeRecording(status: .recording, durationSeconds: 540), at: now))
        #expect(timeline.capturedDuration == 540)
        #expect(timeline.capturedAt == now)
    }

    @Test func `without a measured length the time since capture started counts`() throws {
        let fromStartedAt = try #require(RecordingTimeline(recording: makeRecording(status: .recording), at: now))
        #expect(fromStartedAt.capturedDuration == 600)

        let zeroMeasured = try #require(RecordingTimeline(recording: makeRecording(status: .recording, durationSeconds: 0), at: now))
        #expect(zeroMeasured.capturedDuration == 600)

        // No startedAt yet: the scheduled start stands in.
        let fromStart = try #require(RecordingTimeline(recording: makeRecording(status: .recording, startedAgo: nil), at: now))
        #expect(fromStart.capturedDuration == 900)
    }

    @Test func `the timeline grows with the wall clock until the scheduled end`() {
        let timeline = RecordingTimeline(capturedDuration: 300, capturedAt: now, end: now.addingTimeInterval(60))
        #expect(timeline.duration(at: now) == 300)
        #expect(timeline.duration(at: now.addingTimeInterval(45)) == 345)
        #expect(timeline.duration(at: now.addingTimeInterval(600)) == 360)
        // A clock that reads earlier than the capture never shrinks it.
        #expect(timeline.duration(at: now.addingTimeInterval(-30)) == 300)
    }

    // MARK: - Display duration

    @Test func `without a timeline the engine's duration is used unchanged`() {
        #expect(RecordingTimeline.displayDuration(engineDuration: 145, position: 86, timeline: nil, now: now) == 145)
        #expect(RecordingTimeline.displayDuration(engineDuration: 0, position: 12, timeline: nil, now: now) == 0)
    }

    @Test func `a growing recording spans its captured length when the engine reports none`() {
        let timeline = RecordingTimeline(capturedDuration: 300, capturedAt: now, end: now.addingTimeInterval(3600))
        for engine in [0, -1, .nan, .infinity] as [TimeInterval] {
            let span = RecordingTimeline.displayDuration(engineDuration: engine, position: 20, timeline: timeline, now: now.addingTimeInterval(10))
            #expect(span == 310)
        }
    }

    @Test func `the span never ends before the playhead`() {
        let timeline = RecordingTimeline(capturedDuration: 300, capturedAt: now, end: now.addingTimeInterval(3600))
        #expect(RecordingTimeline.displayDuration(engineDuration: 0, position: 420, timeline: timeline, now: now) == 420)
        #expect(RecordingTimeline.displayDuration(engineDuration: 0, position: .nan, timeline: timeline, now: now) == 300)
    }

    @Test func `a stale engine duration doesn't cap a growing recording`() {
        let timeline = RecordingTimeline(capturedDuration: 300, capturedAt: now, end: now.addingTimeInterval(3600))
        #expect(RecordingTimeline.displayDuration(engineDuration: 240, position: 10, timeline: timeline, now: now) == 300)
        #expect(RecordingTimeline.displayDuration(engineDuration: 900, position: 10, timeline: timeline, now: now) == 900)
    }

    @MainActor
    @Test func `the playback clock falls back only for a growing recording`() {
        let clock = PlaybackClock()
        clock.current = 30
        let timeline = RecordingTimeline(capturedDuration: 300, capturedAt: .now, end: .now.addingTimeInterval(3600))

        #expect(clock.displayDuration(growing: nil) == 0)
        #expect(clock.displayDuration(growing: timeline) >= 300)

        clock.duration = 4000
        #expect(clock.displayDuration(growing: nil) == 4000)
        #expect(clock.displayDuration(growing: timeline) == 4000)
    }

    // MARK: - Playable media

    @Test func `an in-progress recording's media carries its timeline`() throws {
        let recording = makeRecording(status: .recording, durationSeconds: 540)
        let media = try PlayableMedia.recording(recording, grant: makeGrant(), startTime: 0, now: now)

        let timeline = try #require(media.recordingTimeline)
        #expect(timeline.capturedDuration == 540)
        #expect(timeline.end == recording.end)
        #expect(media.startTime == 0)
    }

    @Test func `a finished recording's media has no timeline`() throws {
        let media = try PlayableMedia.recording(makeRecording(status: .completed, durationSeconds: 145), grant: makeGrant(), startTime: 86, now: now)
        #expect(media.recordingTimeline == nil)
    }

    @Test func `the timeline survives engine swaps, URL swaps and Codable`() throws {
        let media = try PlayableMedia.recording(makeRecording(status: .recording), grant: makeGrant(), startTime: 0, now: now)
        let timeline = try #require(media.recordingTimeline)

        #expect(media.resuming(at: 42).recordingTimeline == timeline)
        #expect(try media.replacingURL(#require(URL(string: "http://example.com/other.m3u8"))).recordingTimeline == timeline)
        let decoded = try JSONDecoder().decode(PlayableMedia.self, from: JSONEncoder().encode(media))
        #expect(decoded.recordingTimeline == timeline)
    }
}

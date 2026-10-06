//
//  RecordingLibraryRowTests.swift
//  LumeTests
//
//  The recordings library row's time range: the planned window while a
//  recording is scheduled or running, the captured span once it has ended.
//

import Foundation
@testable import Lume
import LumeRecorderKit
import Testing

@MainActor
struct RecordingLibraryRowTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private var end: Date {
        start.addingTimeInterval(21 * 60)
    }

    private func makeRecording(
        status: RecordingStatus,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        failureReason: String? = nil
    ) -> Recording {
        Recording(
            id: UUID(), title: "Late Show", channelName: nil, channelLogoURL: nil, programmeDescription: nil,
            sourceRef: nil, start: start, end: end, status: status, failureReason: failureReason,
            createdAt: start.addingTimeInterval(-60), startedAt: startedAt, finishedAt: finishedAt,
            durationSeconds: nil, sizeBytes: nil
        )
    }

    @Test func `a recording stopped early shows the span it captured`() {
        let stoppedAt = start.addingTimeInterval(3 * 60)
        let recording = makeRecording(status: .completed, startedAt: start, finishedAt: stoppedAt)
        #expect(recording.displayedTimeRange == start ..< stoppedAt)
        #expect(recording.timeRangeText == (start ..< stoppedAt).formatted(date: .abbreviated, time: .shortened))
    }

    @Test func `failed and cancelled recordings that captured show the captured span`() {
        let startedAt = start.addingTimeInterval(30)
        let finishedAt = start.addingTimeInterval(90)
        for status in [RecordingStatus.failed, .cancelled] {
            let recording = makeRecording(status: status, startedAt: startedAt, finishedAt: finishedAt)
            #expect(recording.displayedTimeRange == startedAt ..< finishedAt)
        }
    }

    @Test func `scheduled and running recordings show the planned window`() {
        #expect(makeRecording(status: .scheduled).displayedTimeRange == start ..< end)
        let running = makeRecording(status: .recording, startedAt: start.addingTimeInterval(5))
        #expect(running.displayedTimeRange == start ..< end)
        // Even with timestamps set, a running recording isn't finished yet.
        let odd = makeRecording(status: .recording, startedAt: start, finishedAt: start.addingTimeInterval(60))
        #expect(odd.displayedTimeRange == start ..< end)
    }

    @Test func `a finished recording that never started keeps the planned window`() {
        let cancelled = makeRecording(status: .cancelled, finishedAt: start.addingTimeInterval(-300))
        #expect(cancelled.displayedTimeRange == start ..< end)
        let missed = makeRecording(status: .failed, finishedAt: end.addingTimeInterval(60), failureReason: "missed")
        #expect(missed.displayedTimeRange == start ..< end)
    }

    @Test func `an unavailable source reads as nothing captured`() {
        let recording = makeRecording(
            status: .failed, startedAt: start, finishedAt: start.addingTimeInterval(20),
            failureReason: "source_unavailable: Error when loading first segment"
        )
        #expect(recording.failureText == makeRecording(status: .failed, failureReason: "no_segments").failureText)
    }
}

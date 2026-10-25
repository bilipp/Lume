//
//  RecordingLibraryRowTests.swift
//  LumeTests
//
//  The recordings library row's time range: the planned window while a
//  recording is scheduled or running, the captured span once it has ended.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct RecordingLibraryRowTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private var end: Date {
        start.addingTimeInterval(21 * 60)
    }

    private func makeRecording(
        status: ServerRecordingStatus,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        failureReason: String? = nil,
        sourceRef: String? = nil
    ) -> ServerRecording {
        ServerRecording(
            id: RecordingID(UUID()), title: "Late Show", sourceRef: sourceRef, start: start, end: end, status: status,
            failureReason: failureReason, createdAt: start.addingTimeInterval(-60),
            startedAt: startedAt, finishedAt: finishedAt
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
        for status in [ServerRecordingStatus.failed, .cancelled] {
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

    // MARK: Per server

    private func kinds(_ actions: [RecordingLibraryAction]) -> [RecordingLibraryAction.Kind] {
        actions.map(\.kind)
    }

    private func actions(
        for recording: ServerRecording,
        on kind: RecordingServerKind = .lumeRecorder,
        capabilities: RecordingServerCapabilities? = nil,
        now: Date = .now
    ) -> [RecordingLibraryAction] {
        RecordingLibraryAction.actions(
            for: recording,
            cancels: kind.capabilities.cancelsRatherThanStops(recording, now: now),
            capabilities: capabilities ?? kind.capabilities
        )
    }

    @Test func `dispatcharr cancels a schedule without a separate delete`() {
        let opened = makeRecording(status: .scheduled)
        let now = start.addingTimeInterval(60)

        #expect(kinds(actions(for: opened, on: .dispatcharr, now: now)) == [.cancel])
        #expect(kinds(actions(for: opened, now: now)) == [.stop, .delete])
        let running = makeRecording(status: .recording, startedAt: start)
        #expect(kinds(actions(for: running, on: .dispatcharr, now: now)) == [.stop, .delete])
        #expect(kinds(actions(for: makeRecording(status: .completed), on: .dispatcharr)) == [.delete])
    }

    @Test func `a view-only account gets no actions`() {
        var viewOnly = RecordingServerCapabilities.dispatcharr
        viewOnly.readOnly = true
        for status in [ServerRecordingStatus.scheduled, .recording, .completed] {
            #expect(actions(for: makeRecording(status: status), on: .dispatcharr, capabilities: viewOnly).isEmpty)
        }
    }

    @Test func `dispatcharr deletes say where the video goes`() throws {
        let running = makeRecording(status: .recording, startedAt: start)
        let lume = try #require(actions(for: running).last)
        let dispatcharr = try #require(actions(for: running, on: .dispatcharr).last)
        let completed = try #require(actions(for: makeRecording(status: .completed), on: .dispatcharr).last)

        #expect(dispatcharr.kind == .delete)
        #expect(dispatcharr.message != lume.message)
        #expect(dispatcharr.message != completed.message)
    }

    @Test func `failures read by reason code`() {
        let generic = makeRecording(status: .failed).failureText
        let interrupted = makeRecording(status: .failed, failureReason: "interrupted")
        let noData = makeRecording(status: .failed, failureReason: "source_unavailable")

        #expect(makeRecording(status: .failed, failureReason: "missed").failureText != generic)
        #expect(interrupted.failureText != generic)
        #expect(noData.failureText == makeRecording(status: .failed, failureReason: "no_segments").failureText)
        #expect(makeRecording(status: .completed).failureText == nil)
    }

    @Test func `a child profile hides recordings Lume didn't make when the server says so`() throws {
        let context = try ModelContext(makeTestContainer())
        let playlistID = UUID()
        context.insert(LiveStream(id: "p-live-1", streamId: 1, name: "Cartoon Cove", categoryId: "kids"))
        context.insert(LiveStream(id: "p-live-2", streamId: 2, name: "Night Owl", categoryId: "late"))
        let open = makeRecording(
            status: .completed, sourceRef: RecordingSourceRef(playlistID: playlistID, streamID: "p-live-1").rawValue
        )
        let restricted = makeRecording(
            status: .completed, sourceRef: RecordingSourceRef(playlistID: playlistID, streamID: "p-live-2").rawValue
        )
        let external = makeRecording(status: .completed)
        let child = ContentRestriction(isActive: true, restrictedCategoryIDs: ["late"])
        let recordings = [open, restricted, external]

        #expect(RecordingsLibrary.hiddenRecordingIDs(recordings, restriction: child, context: context) == [restricted.id])
        #expect(RecordingsLibrary.hiddenRecordingIDs(
            recordings, restriction: child, hidesUnattributed: true, context: context
        ) == [restricted.id, external.id])
        let adult = ContentRestriction(isActive: false, restrictedCategoryIDs: ["late"])
        #expect(RecordingsLibrary.hiddenRecordingIDs(
            recordings, restriction: adult, hidesUnattributed: true, context: context
        ).isEmpty)
    }
}

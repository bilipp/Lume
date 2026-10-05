//
//  EPGProgramDetailView+Recording.swift
//  Lume
//
//  A guide programme's recording action: Record for the programme on air,
//  Schedule Recording for an upcoming one, and Stop / Cancel Recording once
//  the paired server has it. Offered by the programme detail and by the
//  programme's context menu in the touch/pointer guide. Runs through the
//  `.recordActionFlow()` the presenter installs, so the duration choice,
//  toast and paywall show over whatever raised it.
//

import LumeRecorderKit
import SwiftUI

extension EPGProgramDetailView {
    /// Hidden unless a server is paired and the channel's playlist can record.
    var recordActions: some View {
        EPGProgramRecordActions(recording: EPGProgramRecording(stream: stream, cell: cell, now: now))
    }
}

/// What recording a programme means, independent of the control offering it.
struct EPGProgramRecording {
    let stream: LiveStream
    let cell: EPGProgramCell
    let now: Date

    private var programme: RecordingRequestPlanner.Programme? {
        guard !cell.isGap else { return nil }
        return RecordingRequestPlanner.Programme(
            title: cell.title,
            description: cell.detail.isEmpty ? nil : cell.detail,
            start: cell.start,
            end: cell.end
        )
    }

    /// A gap filler on air still records (with the duration choice); only a
    /// listed programme can be scheduled.
    private var timing: RecordingRequestPlanner.ProgrammeTiming {
        if cell.isPast(at: now) {
            return .ended
        }
        return cell.start > now ? .upcoming : .live
    }

    /// `nil` when the programme offers no record action.
    func state(with action: RecordChannelAction) -> RecordProgrammeState? {
        action.programmeState(for: stream, programme: programme, timing: timing)
    }

    func perform(_ state: RecordProgrammeState, with action: RecordChannelAction) {
        switch state {
        case .record:
            action.record(stream, programme: programme)
        case .schedule:
            guard let programme else { return }
            action.schedule(stream, programme: programme)
        case let .cancel(recording), let .stop(recording):
            action.stop(recording)
        case .locked:
            action.showPaywall()
        }
    }

    static func label(
        for state: RecordProgrammeState
    ) -> (title: LocalizedStringKey, systemImage: String, isRecord: Bool, isStop: Bool) {
        switch state {
        case .record:
            ("Record", "record.circle", true, false)
        case .schedule:
            ("Schedule Recording", "record.circle", true, false)
        case .cancel:
            ("Cancel Recording", "xmark.circle", false, true)
        case .stop:
            ("Stop Recording", "stop.circle", false, true)
        case .locked(.upcoming):
            ("Schedule Recording", "crown", false, false)
        case .locked:
            ("Record", "crown", false, false)
        }
    }
}

/// Its own view so the recording-state read is tracked here: a poll that
/// changes the server's recordings re-renders this button, not the sheet.
private struct EPGProgramRecordActions: View {
    let recording: EPGProgramRecording

    @Environment(\.recordChannel) private var recordChannel

    var body: some View {
        if let recordChannel, let state = recording.state(with: recordChannel) {
            actionButton(state, action: recordChannel)
        }
    }

    @ViewBuilder
    private func actionButton(_ state: RecordProgrammeState, action: RecordChannelAction) -> some View {
        let label = EPGProgramRecording.label(for: state)
        #if os(tvOS)
            TVPlayButton(title: label.title, systemImage: label.systemImage) {
                recording.perform(state, with: action)
            }
        #else
            Button(role: label.isStop ? .destructive : nil) {
                recording.perform(state, with: action)
            } label: {
                Label(label.title, systemImage: label.systemImage)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(label.isRecord ? .red : nil)
            .controlSize(.large)
        #endif
    }
}

/// The record item in a programme's context menu. Like the channel menu's
/// Record item it hides where nothing can be recorded, and refreshes stale
/// recordings when the menu builds it — the guide doesn't poll.
struct EPGProgramRecordMenuItem: View {
    let recording: EPGProgramRecording

    @Environment(\.recordChannel) private var recordChannel

    var body: some View {
        if let recordChannel, let state = recording.state(with: recordChannel) {
            let label = EPGProgramRecording.label(for: state)
            Button(role: label.isStop ? .destructive : nil) {
                recording.perform(state, with: recordChannel)
            } label: {
                Label(label.title, systemImage: label.systemImage)
            }
            .task { await RecordingServerStore.shared.refreshIfStale(maxAge: .seconds(30)) }
        }
    }
}

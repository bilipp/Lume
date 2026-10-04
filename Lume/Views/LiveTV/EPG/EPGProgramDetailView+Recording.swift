//
//  EPGProgramDetailView+Recording.swift
//  Lume
//
//  The programme detail's recording action: Record for the programme on air,
//  Schedule Recording for an upcoming one, and Stop / Cancel Recording once
//  the paired server has it. Runs through the `.recordActionFlow()` the
//  presenter installs on the sheet, so the duration choice, toast and paywall
//  show inside it rather than behind it.
//

import LumeRecorderKit
import SwiftUI

extension EPGProgramDetailView {
    /// Hidden unless a server is paired and the channel's playlist can record.
    var recordActions: some View {
        EPGProgramRecordActions(stream: stream, cell: cell, now: now)
    }
}

/// Its own view so the recording-state read is tracked here: a poll that
/// changes the server's recordings re-renders this button, not the sheet.
private struct EPGProgramRecordActions: View {
    let stream: LiveStream
    let cell: EPGProgramCell
    let now: Date

    @Environment(\.recordChannel) private var recordChannel

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
        if cell.isPast(at: now) { return .ended }
        return cell.start > now ? .upcoming : .live
    }

    var body: some View {
        if let recordChannel,
           let state = recordChannel.programmeState(for: stream, programme: programme, timing: timing)
        {
            actionButton(state, action: recordChannel)
        }
    }

    @ViewBuilder
    private func actionButton(_ state: RecordProgrammeState, action: RecordChannelAction) -> some View {
        let label = Self.label(for: state)
        #if os(tvOS)
            TVPlayButton(title: label.title, systemImage: label.systemImage) {
                perform(state, action: action)
            }
        #else
            Button(role: label.isStop ? .destructive : nil) {
                perform(state, action: action)
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

    private func perform(_ state: RecordProgrammeState, action: RecordChannelAction) {
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

    private static func label(
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

//
//  SportsReplayDetail.swift
//  Lume
//
//  Replay actions are embedded in the normal game detail. Playback grants and
//  progress remain owned by RecordingServerStore; no media URLs are persisted.
//

import SwiftUI

struct SportsReplayDetail: View {
    let game: SportsReplayGame
    @State private var model = RecordingsLibraryModel()

    var body: some View {
        detail
            .recordingsLibraryActions(model)
            .preferredColorScheme(.dark)
        #if os(tvOS)
            .fullScreenCover(item: $model.playingMedia) { FullScreenPlayerView(media: $0) }
        #else
            .recordingPlayer(item: $model.playingMedia)
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        #if os(tvOS)
            TVGameDetailSheet(fixture: game.fixture, resolved: [], onWatch: { _ in }, replay: game, onReplay: play)
        #else
            GameDetailSheet(fixture: game.fixture, resolved: [], onWatch: { _ in }, replay: game, onReplay: play)
        #endif
    }

    private func play(_ recording: ServerRecording, fromBeginning: Bool) {
        model.play(recording, fromBeginning: fromBeginning)
    }
}

struct SportsReplayActions: View {
    let game: SportsReplayGame
    var onPlay: (ServerRecording, Bool) -> Void
    @State private var selectedID: RecordingID?

    private var namespace: String? {
        RecordingServerConfigService.shared.activeServer?.progressNamespace
    }

    private var lastVersionKey: String {
        "sports.replayVersion." + (namespace ?? "lumeRecorder") + "." + game.id
    }

    private var selected: ServerRecording? {
        game.recordings.first { $0.id == selectedID }
            ?? game.recordings.first { $0.id.rawValue == UserDefaults.standard.string(forKey: lastVersionKey) }
            ?? game.recordings.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(game.fixture.startDate, format: .dateTime.weekday().month().day().year().hour().minute())
            let metadata = [game.fixture.seasonName, game.fixture.seasonPhase, game.fixture.weekLabel, game.fixture.venue]
                .compactMap(\.self).joined(separator: " · ")
            if !metadata.isEmpty { Text(verbatim: metadata).foregroundStyle(.secondary) }
            if !game.fixture.broadcasters.isEmpty { Text(verbatim: game.fixture.broadcasters.joined(separator: ", ")) }
            if game.recordings.count > 1 {
                Picker("Version", selection: $selectedID) {
                    ForEach(game.recordings) { recording in
                        Text(verbatim: versionLabel(recording)).tag(Optional(recording.id))
                    }
                }
            }
            if let recording = selected {
                Text(verbatim: versionLabel(recording)).font(.caption).foregroundStyle(.secondary)
                if recording.programmeStart.map({ recording.start > $0.addingTimeInterval(60) }) == true || recording.isPartial {
                    Label("Partial recording", systemImage: "circle.lefthalf.filled")
                }
                let progress = RecordingProgressStore.resumePosition(for: recording, namespace: namespace)
                Button {
                    launch(recording, fromBeginning: false)
                } label: {
                    Label(progress > 0 ? String(localized: "Resume") : String(localized: "Watch"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                if progress > 0 {
                    Button("Watch from beginning") { launch(recording, fromBeginning: true) }
                        .frame(minHeight: 44)
                }
            }
        }
        .onAppear { selectedID = selected?.id }
    }

    private func launch(_ recording: ServerRecording, fromBeginning: Bool) {
        UserDefaults.standard.set(recording.id.rawValue, forKey: lastVersionKey)
        onPlay(recording, fromBeginning)
    }

    private func versionLabel(_ recording: ServerRecording) -> String {
        let channel = recording.channelName ?? String(localized: "Recording")
        return String(localized: "Recording") + " · " + channel
    }
}

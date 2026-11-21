//
//  SportsReplayDetail.swift
//  Lume
//
//  Replay actions are embedded in the normal game detail. Playback grants and
//  progress remain owned by RecordingServerStore; no media URLs are persisted.
//

import SwiftData
import SwiftUI

struct SportsReplayDetail: View {
    let game: SportsReplayGame
    @Environment(\.modelContext) private var context
    @State private var model = RecordingsLibraryModel()

    var body: some View {
        detail
            .replayPlayer(model)
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var detail: some View {
        #if os(tvOS)
            TVGameDetailSheet(fixture: game.fixture, resolved: [], onWatch: { _ in }, replay: game, onReplay: play)
        #else
            GameDetailSheet(fixture: game.fixture, resolved: [], onWatch: { _ in }, replay: game, onReplay: play)
        #endif
    }

    private func play(_ version: SportsReplayVersion, fromBeginning: Bool) {
        switch version {
        case let .recording(recording):
            model.play(recording, fromBeginning: fromBeginning)
        case let .library(file):
            let media = file.media(in: context)
            model.playingMedia = fromBeginning ? media?.resuming(at: 0) : media
        }
    }
}

struct SportsReplayActions: View {
    let game: SportsReplayGame
    var onPlay: (SportsReplayVersion, Bool) -> Void
    @State private var selectedID: String?

    private var namespace: String? {
        RecordingServerConfigService.shared.activeServer?.progressNamespace
    }

    private var lastVersionKey: String {
        "sports.replayVersion." + (namespace ?? "lumeRecorder") + "." + game.id
    }

    private var selected: SportsReplayVersion? {
        let versions = game.versions
        return versions.first { $0.id == selectedID }
            ?? versions.first { $0.id == UserDefaults.standard.string(forKey: lastVersionKey) }
            ?? versions.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(game.fixture.startDate, format: .dateTime.weekday().month().day().year().hour().minute())
            let metadata = [game.fixture.seasonName, game.fixture.seasonPhase, game.fixture.weekLabel, game.fixture.venue]
                .compactMap(\.self).joined(separator: " · ")
            if !metadata.isEmpty { Text(verbatim: metadata).foregroundStyle(.secondary) }
            if !game.fixture.broadcasters.isEmpty { Text(verbatim: game.fixture.broadcasters.joined(separator: ", ")) }
            if game.versions.count > 1 {
                Picker("Version", selection: $selectedID) {
                    ForEach(game.versions) { version in
                        Text(verbatim: versionLabel(version)).tag(Optional(version.id))
                    }
                }
            }
            // The store's copy of a recording, not the game's: a capture that
            // finished while the sheet was open is no longer `.recording`, and
            // has a resume point.
            if let version = selected.map({ Self.current($0) }) {
                Text(verbatim: versionLabel(version)).font(.caption).foregroundStyle(.secondary)
                if case let .recording(recording) = version,
                   recording.programmeStart.map({ recording.start > $0.addingTimeInterval(60) }) == true || recording.isPartial
                {
                    Label("Partial recording", systemImage: "circle.lefthalf.filled")
                }
                let progress = progress(of: version)
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        launch(version, fromBeginning: false)
                    } label: {
                        Label(progress > 0 ? String(localized: "Resume") : String(localized: "Watch"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    if progress > 0 {
                        Button("Watch from beginning") { launch(version, fromBeginning: true) }
                            .frame(minHeight: 44)
                    }
                }
                #if os(tvOS)
                // Full width, so Down from any version reaches the actions.
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                #endif
            }
        }
        .onAppear { selectedID = selected?.id }
    }

    private static func current(_ version: SportsReplayVersion) -> SportsReplayVersion {
        guard case let .recording(recording) = version else { return version }
        return .recording(RecordingServerStore.shared.current(recording))
    }

    private func launch(_ version: SportsReplayVersion, fromBeginning: Bool) {
        UserDefaults.standard.set(version.id, forKey: lastVersionKey)
        onPlay(version, fromBeginning)
    }

    private func progress(of version: SportsReplayVersion) -> Double {
        switch version {
        case let .recording(recording): RecordingProgressStore.resumePosition(for: recording, namespace: namespace)
        case let .library(file): file.progress
        }
    }

    private func versionLabel(_ version: SportsReplayVersion) -> String {
        switch version {
        case let .recording(recording):
            String(localized: "Recording") + " · " + (recording.channelName ?? String(localized: "Recording"))
        case let .library(file):
            file.source.isEmpty ? file.title : file.source
        }
    }
}

extension View {
    /// The recordings library's actions and the player its `playingMedia`
    /// opens, as every replay surface presents them: the game sheet, and the
    /// cards that play straight from the list.
    func replayPlayer(_ model: RecordingsLibraryModel) -> some View {
        modifier(ReplayPlayer(model: model))
    }
}

private struct ReplayPlayer: ViewModifier {
    @Bindable var model: RecordingsLibraryModel

    func body(content: Content) -> some View {
        content
            .recordingsLibraryActions(model)
            .recordingPlayer(item: $model.playingMedia)
    }
}

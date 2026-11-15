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
    @Environment(\.contentRestriction) private var restriction
    @State private var unavailable = false
    @State private var model = RecordingsLibraryModel()

    var body: some View {
        detail
            .recordingsLibraryActions(model)
            .preferredColorScheme(.dark)
            .alert("Unable to Play", isPresented: $unavailable) { Button("OK", role: .cancel) {} } message: {
                Text("This replay is no longer available in the current library.")
            }
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

    private func play(_ version: SportsReplayVersion, fromBeginning: Bool) {
        switch version {
        case let .recording(recording): model.play(recording, fromBeginning: fromBeginning)
        case let .library(file):
            guard let media = libraryMedia(file) else { unavailable = true; return }
            model.playingMedia = fromBeginning ? media.resuming(at: 0) : media
        }
    }

    private func libraryMedia(_ file: SportsLibraryVersion) -> PlayableMedia? {
        let playlistID = file.playlistID
        let id = file.catalogID
        guard let playlist = try? context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistID })).first else { return nil }
        switch file.kind {
        case .movie:
            guard let movie = try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })).first,
                  !restriction.hides(categoryID: movie.categoryId) else { return nil }
            return PlayableMedia.from(movie: movie, playlist: playlist)
        case .episode:
            guard let episode = try? context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })).first,
                  !restriction.hides(categoryID: episode.series?.categoryId) else { return nil }
            return PlayableMedia.from(episode: episode, playlist: playlist)
        }
    }
}

struct SportsReplayActions: View {
    let game: SportsReplayGame
    var onPlay: (SportsReplayVersion, Bool) -> Void
    @Environment(\.modelContext) private var context
    @State private var selectedID: String?

    private var namespace: String? {
        RecordingServerConfigService.shared.activeServer?.progressNamespace
    }

    private var lastVersionKey: String {
        "sports.replayVersion." + (namespace ?? "lumeRecorder") + "." + game.id
    }

    private var selected: SportsReplayVersion? {
        game.versions.first { $0.id == selectedID }
            ?? game.versions.first { $0.id == UserDefaults.standard.string(forKey: lastVersionKey) }
            ?? game.versions.first { $0.progress(namespace: namespace, in: context) > 0 }
            ?? game.versions.first
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
                        Text(verbatim: version.label).tag(Optional(version.id))
                    }
                }
            }
            if let version = selected { actions(version) }
        }
        .onAppear { selectedID = selected?.id }
    }

    @ViewBuilder
    private func actions(_ version: SportsReplayVersion) -> some View {
        Text(verbatim: version.label).font(.caption).foregroundStyle(.secondary)
        switch version {
        case let .recording(recording):
            if recording.programmeStart.map({ recording.start > $0.addingTimeInterval(60) }) == true || recording.isPartial {
                Label("Partial recording", systemImage: "circle.lefthalf.filled")
            }
        case let .library(file):
            if file.matchedFromTitle { Text("Matched from title").font(.caption).foregroundStyle(.secondary) }
        }
        let progress = version.progress(namespace: namespace, in: context)
        Button { launch(version, fromBeginning: false) } label: {
            Label(progress > 0 ? String(localized: "Resume") : String(localized: "Watch"), systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .frame(minHeight: 44)
        if progress > 0 {
            Button("Watch from beginning") { launch(version, fromBeginning: true) }.frame(minHeight: 44)
        }
    }

    private func launch(_ version: SportsReplayVersion, fromBeginning: Bool) {
        UserDefaults.standard.set(version.id, forKey: lastVersionKey)
        onPlay(version, fromBeginning)
    }
}

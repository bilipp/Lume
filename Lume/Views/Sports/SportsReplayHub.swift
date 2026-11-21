//
//  SportsReplayHub.swift
//  Lume
//
//  Shared Scores / Replays chrome. The existing recording store owns refresh;
//  profile visibility is applied before matching, including on the first frame.
//

import SwiftData
import SwiftUI

struct SportsReplayHub<Scores: View>: View {
    @Binding var showsReplays: Bool
    @ViewBuilder var scores: () -> Scores
    @Environment(\.modelContext) private var context
    @Environment(\.contentRestriction) private var restriction
    @Environment(\.catalogScope) private var catalogScope
    @State private var recordings = RecordingServerStore.shared
    @State private var sports = SportsStore.shared
    @State private var channels: [String: Set<String>] = [:]
    @AppStorage(SportsSyncService.libraryReplaysKey) private var includesLibrary = false
    @State private var library: [SportsLibraryReplay] = []
    @Query private var playlists: [Playlist]
    /// Bumped as a replay closes: its progress lives in the catalog rows the
    /// library snapshot was read from.
    @State private var playbackRevision = 0

    private var visibleRecordings: [ServerRecording] {
        let hidden = RecordingsLibrary.hiddenRecordingIDs(
            recordings.recordings, restriction: restriction,
            hidesUnattributed: recordings.pairedCapabilities?.listsExternalRecordings ?? false,
            context: context
        )
        return recordings.recordings.filter { !hidden.contains($0.id) }
    }

    private var fixtures: [SportsFixture] {
        sports.snapshots.values.flatMap(\.fixtures)
    }

    /// What the games are derived from. Matching runs when one of these
    /// changes, off the main thread, and never while the view merely renders.
    private nonisolated struct MatchInputs: Equatable {
        let recordings: [ServerRecording]
        let library: [SportsLibraryReplay]
        let fixtures: [SportsFixture]
        let channels: [String: Set<String>]
    }

    @State private var games: [SportsReplayGame] = []
    /// Library files the last match found no fixture for. Derived with the
    /// games, so a file is never listed here merely because matching is pending.
    @State private var others: [SportsLibraryReplay] = []

    var body: some View {
        VStack(spacing: 12) {
            if !games.isEmpty || !others.isEmpty {
                Picker("Sports", selection: $showsReplays) {
                    Text("Scores").tag(false)
                    Text("Replays").tag(true)
                }
                .hubSegmentedPickerStyle()
                .padding(.horizontal)
            }
            if showsReplays, !games.isEmpty || !others.isEmpty {
                SportsReplaysView(games: games, others: others) { playbackRevision += 1 }
            } else {
                scores()
            }
        }
        .observesRecordingServerWhileVisible(isActive: true)
        .task(id: resolutionKey) { await resolveRecordingChannels() }
        .task(id: libraryKey) {
            library = includesLibrary ? SportsReplayLibrary.files(in: context, scope: catalogScope, restriction: restriction) : []
        }
        .task(id: MatchInputs(recordings: visibleRecordings, library: library, fixtures: fixtures, channels: channels)) {
            let inputs = MatchInputs(recordings: visibleRecordings, library: library, fixtures: fixtures, channels: channels)
            let derived = await Task.detached(priority: .userInitiated) {
                let games = SportsReplayLibrary.games(
                    recordings: inputs.recordings, library: inputs.library, fixtures: inputs.fixtures, channels: inputs.channels
                )
                // A file no fixture names is still a replay: listed plainly, never guessed.
                let placed = Set(games.flatMap(\.library).map(\.id))
                return (games, inputs.library.filter { !placed.contains($0.id) })
            }.value
            // Cancelling this task does not stop the detached pass, so a result
            // for inputs that have since changed must not overwrite a newer one.
            guard !Task.isCancelled else { return }
            (games, others) = derived
        }
        .onChange(of: games.isEmpty && others.isEmpty) { _, empty in
            if empty { showsReplays = false }
        }
    }

    /// What the library snapshot is read from: the switch, the scope, the
    /// catalog as last synced or lazily loaded, and the progress playback left.
    private var libraryKey: String {
        let synced = playlists.compactMap { $0.lastSyncDate?.timeIntervalSince1970 }.max() ?? 0
        return "\(includesLibrary)-\(catalogScope.token)-\(restriction.visibilityToken)-\(synced)"
            + "-\(SportsSyncService.shared.replayLibraryRevision)-\(playbackRevision)"
    }

    /// Includes whether each recording is replayable: one that starts
    /// capturing joins the recordings resolved, under the same id and start.
    private var resolutionKey: String {
        visibleRecordings.map { $0.id.rawValue + String($0.start.timeIntervalSince1970) + String($0.isReplayable) }.joined(separator: ",")
            + String(fixtures.reduce(into: 0) { $0 ^= $1.replayKey.hashValue })
            + restriction.visibilityToken
    }

    private func resolveRecordingChannels() async {
        let recordings = visibleRecordings.filter(\.isReplayable)
        let fixtures = fixtures.filter { fixture in
            recordings.contains { fixture.startDate >= $0.start && fixture.startDate < $0.end }
        }
        guard !fixtures.isEmpty else { channels = [:]; return }
        let resolved = await SportsChannelResolver.resolve(
            container: context.container, fixtures: fixtures, now: Date(), restriction: restriction, includeFinished: true
        )
        guard !Task.isCancelled else { return }
        channels = Dictionary(fixtures.map { fixture in
            let refs = (resolved[fixture.id] ?? []).map { RecordingSourceRef(playlistID: $0.playlistID, streamID: $0.stream.id).rawValue }
            return (fixture.replayKey, Set(refs))
        }, uniquingKeysWith: { first, _ in first })
    }
}

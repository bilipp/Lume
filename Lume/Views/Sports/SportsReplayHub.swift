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
    @State private var recordings = RecordingServerStore.shared
    @State private var sports = SportsStore.shared
    @State private var channels: [String: Set<String>] = [:]

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

    private var games: [SportsReplayGame] {
        SportsReplayLibrary.games(recordings: visibleRecordings, fixtures: fixtures, channels: channels)
    }

    var body: some View {
        let games = games
        VStack(spacing: 12) {
            if !games.isEmpty {
                Picker("Sports", selection: $showsReplays) {
                    Text("Scores").tag(false)
                    Text("Replays").tag(true)
                }
                .hubSegmentedPickerStyle()
                .padding(.horizontal)
            }
            if showsReplays, !games.isEmpty {
                SportsReplaysView(games: games)
            } else {
                scores()
            }
        }
        .observesRecordingServerWhileVisible(isActive: true)
        .task(id: resolutionKey) { await resolveRecordingChannels() }
        .onChange(of: games.isEmpty) { _, empty in
            if empty { showsReplays = false }
        }
    }

    private var resolutionKey: String {
        visibleRecordings.map { $0.id.rawValue + String($0.start.timeIntervalSince1970) }.joined(separator: ",")
            + fixtures.map { $0.leagueId + $0.id }.sorted().joined(separator: ",")
            + String(describing: restriction)
    }

    private func resolveRecordingChannels() async {
        let recordings = visibleRecordings.filter { $0.status == .completed || $0.status == .recording }
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
            return (fixture.leagueId + ":" + fixture.id, Set(refs))
        }, uniquingKeysWith: { first, _ in first })
    }
}

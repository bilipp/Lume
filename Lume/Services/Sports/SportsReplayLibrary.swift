//
//  SportsReplayLibrary.swift
//  Lume
//
//  A recording becomes a replay only with one unambiguous fixture. Callers
//  apply RecordingsLibrary visibility before handing recordings to this helper.
//  Derived values stay outside SwiftData and share the live guide's team matcher.
//

import Foundation

nonisolated struct SportsReplayGame: Identifiable, Hashable {
    let fixture: SportsFixture
    let recordings: [ServerRecording]

    var id: String {
        fixture.replayKey
    }

    var addedAt: Date {
        recordings.map(\.createdAt).max() ?? fixture.startDate
    }
}

nonisolated extension SportsFixture {
    /// ESPN event ids are unique per league only.
    var replayKey: String {
        leagueId + ":" + id
    }
}

nonisolated extension ServerRecording {
    /// A recording that holds something to watch.
    var isReplayable: Bool {
        status == .completed || status == .recording
    }
}

nonisolated enum SportsReplayLibrary {
    /// The original programme can identify a partial captured after kickoff.
    /// It is used only with team evidence, never for the channel-only fallback.
    static func games(
        recordings: [ServerRecording],
        fixtures: [SportsFixture],
        channels: [String: Set<String>] = [:],
        aliases: SportsTeamAliases = .bundled
    ) -> [SportsReplayGame] {
        let uniqueFixtures = Dictionary(fixtures.map { ($0.replayKey, $0) }, uniquingKeysWith: { first, _ in first })
        var versions: [String: [ServerRecording]] = [:]
        for recording in recordings where recording.isReplayable {
            let start = recording.programmeStart ?? recording.start
            let end = recording.programmeEnd ?? recording.end
            guard start < end else { continue }
            let candidates = uniqueFixtures.values.filter { $0.startDate >= start && $0.startDate < end }
            let programme = EPGProgramCandidate(
                channelId: recording.sourceRef ?? "", title: recording.title,
                listingDescription: recording.programmeDescription ?? "", start: start, end: end
            )
            let named = candidates.filter {
                SportsMatcher.bestMatch(for: $0, in: [programme], aliases: aliases, requiresKickoffStart: false) != nil
            }
            let match: SportsFixture?
            if named.count == 1 {
                match = named.first
            } else if named.isEmpty, !namesAnyTeam(recording, fixtures: Array(candidates), aliases: aliases),
                      let ref = recording.sourceRef.flatMap(RecordingSourceRef.init(rawValue:))
            {
                let fallback = candidates.filter {
                    $0.startDate >= recording.start && $0.startDate < recording.end
                        && channels[$0.replayKey]?.contains(ref.rawValue) == true
                }
                match = fallback.count == 1 ? fallback.first : nil
            } else {
                match = nil
            }
            guard let match else { continue }
            versions[match.replayKey, default: []].append(recording)
        }
        return versions.compactMap { key, recordings in
            guard let fixture = uniqueFixtures[key] else { return nil }
            return SportsReplayGame(fixture: fixture, recordings: recordings.sorted { $0.createdAt > $1.createdAt })
        }.sorted { $0.fixture.startDate > $1.fixture.startDate }
    }

    private static func namesAnyTeam(_ recording: ServerRecording, fixtures: [SportsFixture], aliases: SportsTeamAliases) -> Bool {
        let haystack = SportsMatcher.normalize(recording.title + " " + String((recording.programmeDescription ?? "").prefix(200)))
        return fixtures.contains { fixture in
            [fixture.home?.team, fixture.away?.team].compactMap(\.self).contains { team in
                SportsMatcher.tokens(for: team, aliases: aliases).contains { haystack.contains(" \($0) ") }
            }
        }
    }
}

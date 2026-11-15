//
//  SportarrResolutionTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import Testing

struct SportarrResolutionTests {
    private func file(_ number: Int, league: String? = nil, date: Date? = nil) -> SportarrIndexedFile {
        SportarrIndexedFile(file: SportarrImportFile(
            catalogID: "file-\(number)", kind: .episode, eventID: "ev-\(100_000 + number)", title: "Giants at Commanders",
            date: date, seriesID: "series", seriesTitle: "NFL", leagueID: league, libraryTitle: "Sports", seasonNumber: 2026,
            fileName: "game.mkv", fingerprint: String(number)
        ))
    }

    @Test func `off prevents every metadata and fixture request`() async {
        let client = MetadataProbe()
        var index = SportarrPlaylistIndex(playlistID: UUID())
        index.files["one"] = file(1, league: "lg-000032")
        let result = await SportarrResolutionPass(client: client, isEnabled: { false }, fixtures: { _, _ in
            Issue.record("Opt-out must not request ESPN history")
            return []
        }).run(index)
        #expect(await client.calls.isEmpty)
        #expect(result.index.files["one"]?.lookupFailures == 0)
    }

    @Test func `event traffic is capped at twenty five and versions share one answer`() async {
        let client = MetadataProbe()
        var index = SportarrPlaylistIndex(playlistID: UUID())
        for number in 0 ..< 35 {
            index.files[String(number)] = file(number)
        }
        index.files["second-version"] = file(0)
        let result = await SportarrResolutionPass(client: client, isEnabled: { true }).run(index)
        #expect(await client.calls.count == 25)
        #expect(result.index.files.values.count(where: { $0.resolution == .notFound }) == 26)
        #expect(result.index.files.values.count(where: { $0.resolution == .pending }) == 10)
    }

    @Test func `season resolves the whole batch and stays cached`() async throws {
        let client = try MetadataProbe(season: JSONDecoder().decode(SportarrSeason.self, from: Data(#"{"episodes":[{"id":"ev-100000"},{"id":"ev-100001"},{"id":"ev-100002"}]}"#.utf8)))
        var index = SportarrPlaylistIndex(playlistID: UUID())
        for number in 0 ..< 3 {
            index.files[String(number)] = file(number, league: "lg-000032")
        }
        let pass = SportarrResolutionPass(client: client, isEnabled: { true })
        let first = await pass.run(index)
        #expect(first.index.files.values.allSatisfy { $0.resolution == .resolved })
        #expect(await client.calls == ["series", "season"])
        _ = await pass.run(first.index)
        #expect(await client.calls == ["series", "season"])
    }

    @Test func `an outage preserves retry state and resolved answers`() async {
        let client = MetadataProbe(unavailable: true)
        var index = SportarrPlaylistIndex(playlistID: UUID())
        index.files["one"] = file(1)
        let result = await SportarrResolutionPass(client: client, isEnabled: { true }).run(index)
        #expect(result.unavailable)
        #expect(result.index.files["one"]?.lookupFailures == 0)
        #expect(result.index.files["one"]?.nextLookupAt == nil)
    }

    @Test func `successful empty historical months are not fetched again`() async {
        let counter = FixtureProbe()
        let client = MetadataProbe()
        var index = SportarrPlaylistIndex(playlistID: UUID())
        index.files["one"] = file(1, date: SportarrEpisode.day("2026-11-12"))
        let pass = SportarrResolutionPass(client: client, isEnabled: { true }, fixtures: { _, _ in await counter.fetch() })
        let first = await pass.run(index)
        #expect(await counter.calls == 1)
        #expect(first.index.historicalFixtures.values.first?.isEmpty == true)
        _ = await pass.run(first.index)
        #expect(await counter.calls == 1)
    }

    @Test func `title parsing and league mapping do not classify a file`() {
        #expect(SportarrFixtureBridge.teams(in: "New York Giants at Washington Commanders - Full Game (2026-11-12)") == ["New York Giants", "Washington Commanders"])
        #expect(SportarrFixtureBridge.teams(in: "Giants at Commanders vs Lions") == nil)
        #expect(SportarrFixtureBridge.league(title: "NFL")?.id == "espn:football/nfl")
        #expect(SportarrFixtureBridge.league(title: "Unreviewed Football League") == nil)
        #expect(SportarrFixtureBridge.fileDate(serverDate: nil, title: "Game (2026-11-12)") == SportarrEpisode.day("2026-11-12"))
    }
}

private actor MetadataProbe: SportarrMetadataProvider {
    private(set) var calls: [String] = []
    private let seasonResponse: SportarrSeason?
    private let unavailable: Bool

    init(season: SportarrSeason? = nil, unavailable: Bool = false) {
        seasonResponse = season
        self.unavailable = unavailable
    }

    func episode(_ id: String) -> SportarrLookup<SportarrEpisode> {
        calls.append(id)
        return unavailable ? .unavailable : .missing
    }

    func series(_: String) -> SportarrLookup<SportarrSeries> {
        calls.append("series")
        return .found(SportarrSeries(id: "lg-000032", title: "NFL", sport: "American Football"))
    }

    func season(leagueID _: String, number _: Int) -> SportarrLookup<SportarrSeason> {
        calls.append("season")
        return seasonResponse.map(SportarrLookup.found) ?? .missing
    }
}

private actor FixtureProbe {
    private(set) var calls = 0
    func fetch() -> [SportsFixture] {
        calls += 1; return []
    }
}

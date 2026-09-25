//
//  SportsStoreTests.swift
//  LumeTests
//
//  Fills the gaps around the in-memory hub store the resolver/sync suites don't
//  reach: the cross-league per-day fixture merge and its sort, team/palette
//  lookup by full id vs raw provider id, the in-progress flag live polling keys
//  off, and the pure quality-badge parser the channel rows show.
//

import Foundation
@testable import Lume
import Testing

// MARK: - Quality badge

struct SportsQualityBadgeTests {
    @Test func `reports the most specific token first`() {
        #expect(sportsQualityBadge(from: "Sky Sport 4K UHD") == "4K")
        #expect(sportsQualityBadge(from: "DAZN 1 UHD") == "UHD")
        #expect(sportsQualityBadge(from: "DAZN 1 FHD") == "FHD")
        #expect(sportsQualityBadge(from: "BT Sport HD") == "HD")
    }

    @Test func `is case insensitive`() {
        #expect(sportsQualityBadge(from: "canal+ fhd") == "FHD")
        #expect(sportsQualityBadge(from: "sky 4k") == "4K")
    }

    @Test func `returns nil when no quality token is present`() {
        #expect(sportsQualityBadge(from: "Sky Bundesliga") == nil)
        #expect(sportsQualityBadge(from: "") == nil)
    }
}

// MARK: - Store day merge / lookups

@MainActor
struct SportsStoreTests {
    private func gregorianUTC() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = dayOfMonth
        comps.hour = hour
        return gregorianUTC().date(from: comps)!
    }

    private func fixture(id: String, leagueId: String, start: Date) -> SportsFixture {
        SportsFixture(
            id: id,
            leagueId: leagueId,
            leagueName: "League",
            leagueAbbreviation: "LG",
            startDate: start,
            status: SportsFixtureStatus(state: .scheduled)
        )
    }

    private func store() -> SportsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SportsStore(cache: SportsCacheStore(directory: dir))
    }

    @Test func `fixtures(for:) merges leagues, filters to the day and sorts by kickoff`() {
        let store = store()
        let ger = "espn:soccer/ger.1"
        let eng = "espn:soccer/eng.1"
        store.update(SportsLeagueSnapshot(fixtures: [
            fixture(id: "ger-late", leagueId: ger, start: day(2026, 9, 18, hour: 20)),
            fixture(id: "ger-other-day", leagueId: ger, start: day(2026, 9, 19, hour: 15))
        ]), for: ger)
        store.update(SportsLeagueSnapshot(fixtures: [
            fixture(id: "eng-early", leagueId: eng, start: day(2026, 9, 18, hour: 14))
        ]), for: eng)

        let today = store.fixtures(for: day(2026, 9, 18), calendar: gregorianUTC())
        #expect(today.map(\.id) == ["eng-early", "ger-late"])
    }

    @Test func `fixtures(for:) is empty when nothing kicks off that day`() {
        let store = store()
        store.update(SportsLeagueSnapshot(fixtures: [
            fixture(id: "1", leagueId: "espn:soccer/ger.1", start: day(2026, 9, 18))
        ]), for: "espn:soccer/ger.1")
        #expect(store.fixtures(for: day(2026, 9, 20), calendar: gregorianUTC()).isEmpty)
    }

    @Test func `team(by:) resolves by full id and by raw provider id`() {
        let store = store()
        let leagueId = "espn:soccer/ger.1"
        let team = SportsTeam(leagueId: leagueId, teamId: "132", name: "Bayern", shortName: "Bayern", abbreviation: "FCB", colorHex: "dc052d")
        store.update(SportsLeagueSnapshot(teams: [team]), for: leagueId)

        #expect(store.team(by: "espn:soccer/ger.1:132")?.name == "Bayern")
        #expect(store.team(by: "132")?.name == "Bayern")
        #expect(store.team(by: "999") == nil)
    }

    @Test func `palette(for:) returns the cached colour pair or nil when uncached`() {
        let store = store()
        let leagueId = "espn:soccer/ger.1"
        let team = SportsTeam(
            leagueId: leagueId, teamId: "132", name: "Bayern", shortName: "Bayern",
            abbreviation: "FCB", colorHex: "dc052d", alternateColorHex: "ffffff"
        )
        store.update(SportsLeagueSnapshot(teams: [team]), for: leagueId)

        let palette = store.palette(for: "espn:soccer/ger.1:132")
        #expect(palette?.primaryHex == "dc052d")
        #expect(palette?.alternateHex == "ffffff")
        #expect(store.palette(for: "espn:soccer/ger.1:000") == nil)
    }

    @Test func `isInProgress reflects the fixture state`() {
        let live = SportsFixture(
            id: "live", leagueId: "espn:soccer/ger.1", leagueName: "L", leagueAbbreviation: "L",
            startDate: Date(), status: SportsFixtureStatus(state: .inProgress)
        )
        let done = SportsFixture(
            id: "done", leagueId: "espn:soccer/ger.1", leagueName: "L", leagueAbbreviation: "L",
            startDate: Date(), status: SportsFixtureStatus(state: .final)
        )
        #expect(live.isInProgress)
        #expect(!done.isInProgress)
    }

    // MARK: - Display order

    private func fixture(_ id: String, state: SportsFixtureState, hour: Int, league: String = "espn:soccer/ger.1") -> SportsFixture {
        SportsFixture(
            id: id, leagueId: league, leagueName: "L", leagueAbbreviation: "L",
            startDate: day(2026, 9, 19, hour: hour), status: SportsFixtureStatus(state: state)
        )
    }

    @Test func `displayOrder puts live first, then upcoming by kickoff, then finished newest-first`() {
        let fixtures = [
            fixture("done-early", state: .final, hour: 13),
            fixture("later", state: .scheduled, hour: 20),
            fixture("done-late", state: .final, hour: 15),
            fixture("soon", state: .scheduled, hour: 18),
            fixture("live", state: .inProgress, hour: 16),
            fixture("postponed", state: .postponed, hour: 19)
        ]
        let ordered = fixtures.sorted(by: SportsFixture.displayOrder).map(\.id)
        #expect(ordered == ["live", "soon", "postponed", "later", "done-late", "done-early"])
    }

    @Test func `displayOrder is deterministic for equal kickoffs`() {
        let fixtures = [
            fixture("b", state: .scheduled, hour: 15, league: "espn:soccer/ger.1"),
            fixture("a", state: .scheduled, hour: 15, league: "espn:soccer/ger.1"),
            fixture("z", state: .scheduled, hour: 15, league: "espn:soccer/eng.1")
        ]
        let once = fixtures.sorted(by: SportsFixture.displayOrder).map(\.id)
        let again = fixtures.reversed().sorted(by: SportsFixture.displayOrder).map(\.id)
        #expect(once == ["z", "a", "b"])
        #expect(once == again)
    }
}

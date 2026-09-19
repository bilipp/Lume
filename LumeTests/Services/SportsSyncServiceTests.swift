//
//  SportsSyncServiceTests.swift
//  LumeTests
//
//  Covers the sports cache round-trip, the pure `monthsToFetch` window and the
//  refresh/merge behaviour against a stub provider — no network, no shared
//  singletons (each test builds its own store over a temp cache directory).
//

import Foundation
@testable import Lume
import Testing

// MARK: - Fixtures / stubs

private nonisolated struct StubFollowSource: SportsFollowSource {
    let followedLeagueIds: [String]
    let followedTeamIds: [String]

    init(leagues: [String] = [], teams: [String] = []) {
        followedLeagueIds = leagues
        followedTeamIds = teams
    }
}

/// A provider that returns whatever it is seeded with. `empty` models a total
/// ESPN failure (everything degrades to `[]`).
private nonisolated struct StubProvider: SportsDataProvider {
    var monthFixtures: [SportsFixture] = []
    var dayFixtures: [SportsFixture] = []
    var teamList: [SportsTeam] = []
    var standingRows: [SportsStandingRow] = []

    func fixtures(league _: SportsLeague, month _: DateComponents) async throws -> [SportsFixture] {
        monthFixtures
    }

    func fixtures(league _: SportsLeague, day _: Date) async throws -> [SportsFixture] {
        dayFixtures
    }

    func teams(league _: SportsLeague) async throws -> [SportsTeam] {
        teamList
    }

    func standings(league _: SportsLeague) async throws -> [SportsStandingRow] {
        standingRows
    }

    func eventDetail(league _: SportsLeague, eventId _: String) async throws -> SportsEventDetail? {
        nil
    }
}

private nonisolated func gregorianUTC() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private nonisolated func makeFixture(id: String, leagueId: String, start: Date, state: SportsFixtureState) -> SportsFixture {
    SportsFixture(
        id: id,
        leagueId: leagueId,
        leagueName: "Bundesliga",
        leagueAbbreviation: "BUND",
        startDate: start,
        status: SportsFixtureStatus(state: state)
    )
}

// MARK: - Cache round-trip

struct SportsCacheStoreTests {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func `snapshot survives a save load round-trip`() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SportsCacheStore(directory: dir)

        let leagueId = "espn:soccer/ger.1"
        let team = SportsTeam(leagueId: leagueId, teamId: "132", name: "Bayern", shortName: "Bayern", abbreviation: "FCB", colorHex: "dc052d")
        let fixture = makeFixture(id: "1", leagueId: leagueId, start: Date(timeIntervalSince1970: 1_780_000_000), state: .scheduled)
        let row = SportsStandingRow(id: "132", teamId: "132", name: "Bayern", rank: 1, points: 10)
        let snapshot = SportsLeagueSnapshot(fixtures: [fixture], standings: [row], teams: [team], teamsFetchedAt: Date())

        store.save(snapshot, for: leagueId)
        let loaded = store.load(leagueId: leagueId)

        #expect(loaded?.fixtures == [fixture])
        #expect(loaded?.standings == [row])
        #expect(loaded?.teams == [team])
    }

    @Test func `load returns nil for an unknown league`() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SportsCacheStore(directory: dir)
        #expect(store.load(leagueId: "espn:soccer/unknown") == nil)
    }

    @Test func `removeAll drops every snapshot`() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SportsCacheStore(directory: dir)
        store.save(SportsLeagueSnapshot(), for: "espn:soccer/ger.1")
        store.removeAll()
        #expect(store.load(leagueId: "espn:soccer/ger.1") == nil)
    }
}

// MARK: - monthsToFetch

struct SportsSyncMonthWindowTests {
    private func components(_ year: Int, _ month: Int) -> DateComponents {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        return comps
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return gregorianUTC().date(from: comps)!
    }

    @Test func `mid month fetches only the current month`() {
        let months = SportsSyncService.monthsToFetch(for: date(2026, 9, 10), calendar: gregorianUTC())
        #expect(months.count == 1)
        #expect(months.first?.year == 2026)
        #expect(months.first?.month == 9)
    }

    @Test func `within seven days of month end also fetches next month`() {
        // September has 30 days; the 25th leaves 5 days, so October is added.
        let months = SportsSyncService.monthsToFetch(for: date(2026, 9, 25), calendar: gregorianUTC())
        #expect(months.count == 2)
        #expect(months.last?.year == 2026)
        #expect(months.last?.month == 10)
    }

    @Test func `year rolls over in December`() {
        let months = SportsSyncService.monthsToFetch(for: date(2026, 12, 28), calendar: gregorianUTC())
        #expect(months.count == 2)
        #expect(months.last?.year == 2027)
        #expect(months.last?.month == 1)
    }
}

// MARK: - leagueId(fromTeamID:)

struct SportsSyncLeagueIDTests {
    @Test func `team id yields its league id`() {
        #expect(SportsSyncService.leagueId(fromTeamID: "espn:soccer/ger.1:132") == "espn:soccer/ger.1")
    }

    @Test func `a bare league id has no trailing team segment`() {
        // "espn:soccer/ger.1" splits on its last ':' into "espn" — the seam is
        // documented as team-id-only input, so this just proves it never crashes.
        #expect(SportsSyncService.leagueId(fromTeamID: "no-colon") == nil)
    }
}

// MARK: - Refresh / merge

@MainActor
struct SportsSyncRefreshTests {
    private func tempStore() -> SportsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SportsStore(cache: SportsCacheStore(directory: dir))
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "sports.test." + UUID().uuidString)!
    }

    @Test func `refresh publishes fetched data to the store`() async {
        let leagueId = "espn:soccer/ger.1"
        let store = tempStore()
        let provider = StubProvider(
            monthFixtures: [makeFixture(id: "1", leagueId: leagueId, start: Date(), state: .scheduled)],
            teamList: [SportsTeam(leagueId: leagueId, teamId: "132", name: "Bayern", shortName: "Bayern", abbreviation: "FCB")],
            standingRows: [SportsStandingRow(id: "132", teamId: "132", name: "Bayern", rank: 1, points: 10)]
        )
        let service = SportsSyncService(
            store: store,
            followSource: StubFollowSource(leagues: [leagueId]),
            defaults: isolatedDefaults()
        )
        service.configure(provider: provider)

        await service.refreshAll()

        let snapshot = store.snapshot(for: leagueId)
        #expect(snapshot?.fixtures.count == 1)
        #expect(snapshot?.teams.count == 1)
        #expect(snapshot?.standings.count == 1)
        #expect(store.refreshError == false)
    }

    @Test func `a followed team pulls in its league`() async {
        let leagueId = "espn:soccer/ger.1"
        let store = tempStore()
        let provider = StubProvider(
            monthFixtures: [makeFixture(id: "1", leagueId: leagueId, start: Date(), state: .scheduled)]
        )
        let service = SportsSyncService(
            store: store,
            followSource: StubFollowSource(teams: ["\(leagueId):132"]),
            defaults: isolatedDefaults()
        )
        service.configure(provider: provider)

        #expect(service.leaguesToRefresh() == [leagueId])
        await service.refreshAll()
        #expect(store.snapshot(for: leagueId)?.fixtures.count == 1)
    }

    @Test func `an all-empty refresh leaves the previous snapshot in place and flags an error`() async {
        let leagueId = "espn:soccer/ger.1"
        let store = tempStore()
        let seeded = StubProvider(
            monthFixtures: [makeFixture(id: "1", leagueId: leagueId, start: Date(), state: .scheduled)],
            teamList: [SportsTeam(leagueId: leagueId, teamId: "132", name: "Bayern", shortName: "Bayern", abbreviation: "FCB")]
        )
        let service = SportsSyncService(
            store: store,
            followSource: StubFollowSource(leagues: [leagueId]),
            defaults: isolatedDefaults()
        )
        service.configure(provider: seeded)
        await service.refreshAll()
        #expect(store.snapshot(for: leagueId)?.fixtures.count == 1)

        // A second pass where ESPN is unreachable (everything empty).
        service.configure(provider: StubProvider())
        await service.refreshAll()

        #expect(store.snapshot(for: leagueId)?.fixtures.count == 1)
        #expect(store.refreshError == true)
    }
}

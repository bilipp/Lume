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

/// Records which days a provider was asked for, so the day-based refreshes can
/// be checked for what they fetch (not just what they publish).
private final nonisolated class DayRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var days: [Date] = []

    func record(_ day: Date) {
        lock.lock()
        days.append(day)
        lock.unlock()
    }

    var requested: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return days
    }
}

/// Counts month requests, so "did this league get fetched again?" can be asked
/// of the provider rather than inferred from the store.
private final nonisolated class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// A provider that returns whatever it is seeded with. `empty` models a total
/// ESPN failure (everything degrades to `[]`). Day fetches return the seeded
/// fixtures that fall on the requested day, so a catch-up over several days
/// merges only what each day actually holds.
private nonisolated struct StubProvider: SportsDataProvider {
    var monthFixtures: [SportsFixture] = []
    var dayFixtures: [SportsFixture] = []
    var teamList: [SportsTeam] = []
    var standingRows: [SportsStandingRow] = []
    var dayLog: DayRequestLog?
    var monthCalls: RequestCounter?

    func fixtures(league _: SportsLeague, month _: DateComponents) async throws -> [SportsFixture] {
        monthCalls?.increment()
        return monthFixtures
    }

    func fixtures(league _: SportsLeague, day: Date) async throws -> [SportsFixture] {
        dayLog?.record(day)
        return dayFixtures.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }
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

// MARK: - Overdue / catch-up rules

struct SportsSyncOverdueTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let leagueId = "espn:soccer/ger.1"

    private func fixture(_ id: String, startingIn offset: TimeInterval, state: SportsFixtureState) -> SportsFixture {
        makeFixture(id: id, leagueId: leagueId, start: now.addingTimeInterval(offset), state: state)
    }

    @Test func `a scheduled game whose kickoff has passed is overdue`() {
        #expect(SportsSyncService.isOverdue(fixture("1", startingIn: -3 * 3600, state: .scheduled), now: now))
    }

    @Test func `a game still live since last night is overdue`() {
        #expect(SportsSyncService.isOverdue(fixture("1", startingIn: -20 * 3600, state: .inProgress), now: now))
    }

    @Test func `an upcoming game is not overdue`() {
        #expect(!SportsSyncService.isOverdue(fixture("1", startingIn: 3600, state: .scheduled), now: now))
    }

    @Test func `finished and postponed games are never overdue`() {
        #expect(!SportsSyncService.isOverdue(fixture("1", startingIn: -3600, state: .final), now: now))
        #expect(!SportsSyncService.isOverdue(fixture("2", startingIn: -3600, state: .postponed), now: now))
    }

    @Test func `a game stuck live beyond the lookback is left to the scheduled refresh`() {
        let tooOld = -(SportsSyncService.overdueLookback + 3600)
        #expect(!SportsSyncService.isOverdue(fixture("1", startingIn: tooOld, state: .inProgress), now: now))
    }

    @Test func `poll days are the overdue fixtures' own days, unique and sorted`() {
        let calendar = gregorianUTC()
        let fixtures = [
            fixture("today-a", startingIn: -2 * 3600, state: .inProgress),
            fixture("today-b", startingIn: -3 * 3600, state: .scheduled),
            fixture("yesterday", startingIn: -26 * 3600, state: .inProgress),
            fixture("upcoming", startingIn: 3600, state: .scheduled),
            fixture("done", startingIn: -5 * 3600, state: .final)
        ]
        let days = SportsSyncService.pollDays(fixtures: fixtures, now: now, calendar: calendar)
        let yesterday = calendar.startOfDay(for: now.addingTimeInterval(-26 * 3600))
        #expect(days == [yesterday, calendar.startOfDay(for: now)])
    }

    @Test func `nothing live or overdue means no poll days`() {
        let fixtures = [
            fixture("upcoming", startingIn: 3600, state: .scheduled),
            fixture("done", startingIn: -5 * 3600, state: .final)
        ]
        #expect(SportsSyncService.pollDays(fixtures: fixtures, now: now).isEmpty)
    }

    @Test func `catch-up always covers today and yesterday`() throws {
        let calendar = gregorianUTC()
        let days = SportsSyncService.catchUpDays(fixtures: [], now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        #expect(try days == [#require(calendar.date(byAdding: .day, value: -1, to: today)), today])
    }

    @Test func `catch-up adds the day of an older overdue fixture`() {
        let calendar = gregorianUTC()
        let twoDaysAgo = fixture("stuck", startingIn: -50 * 3600, state: .inProgress)
        let days = SportsSyncService.catchUpDays(fixtures: [twoDaysAgo], now: now, calendar: calendar)
        #expect(days.count == 3)
        #expect(days.first == calendar.startOfDay(for: twoDaysAgo.startDate))
    }

    @Test func `catch-up is needed with no snapshot or a snapshot older than the threshold`() {
        #expect(SportsSyncService.needsCatchUp(newestFetch: nil, now: now))
        #expect(SportsSyncService.needsCatchUp(newestFetch: now.addingTimeInterval(-20 * 60), now: now))
        #expect(!SportsSyncService.needsCatchUp(newestFetch: now.addingTimeInterval(-5 * 60), now: now))
    }
}

// MARK: - Catch-up refresh

@MainActor
struct SportsSyncCatchUpTests {
    private func tempStore() -> SportsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SportsStore(cache: SportsCacheStore(directory: dir))
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "sports.test." + UUID().uuidString)!
    }

    @Test func `catch-up closes out a game the stale snapshot still calls scheduled`() async throws {
        let leagueId = "espn:soccer/ger.1"
        let store = tempStore()
        let kickoff = Date().addingTimeInterval(-4 * 3600)
        let stale = SportsLeagueSnapshot(
            fetchedAt: Date().addingTimeInterval(-8 * 3600),
            fixtures: [
                makeFixture(id: "played", leagueId: leagueId, start: kickoff, state: .scheduled),
                makeFixture(id: "next-week", leagueId: leagueId, start: Date().addingTimeInterval(6 * 86400), state: .scheduled)
            ]
        )
        store.update(stale, for: leagueId)

        let log = DayRequestLog()
        let provider = StubProvider(
            dayFixtures: [makeFixture(id: "played", leagueId: leagueId, start: kickoff, state: .final)],
            dayLog: log
        )
        let service = SportsSyncService(
            store: store,
            followSource: StubFollowSource(leagues: [leagueId]),
            defaults: isolatedDefaults()
        )
        service.configure(provider: provider)

        await service.catchUp()

        let fixtures = store.snapshot(for: leagueId)?.fixtures ?? []
        #expect(fixtures.first { $0.id == "played" }?.status.state == .final)
        // The rest of the month is left intact, not replaced by the day fetch.
        #expect(fixtures.contains { $0.id == "next-week" })
        // Today and yesterday were asked for, nothing else.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let requested = Set(log.requested.map { calendar.startOfDay(for: $0) })
        #expect(try requested == [today, #require(calendar.date(byAdding: .day, value: -1, to: today))])
    }

    @Test func `catch-up over an unreachable provider leaves the snapshot untouched`() async {
        let leagueId = "espn:soccer/ger.1"
        let store = tempStore()
        let kickoff = Date().addingTimeInterval(-4 * 3600)
        let stale = SportsLeagueSnapshot(
            fetchedAt: Date().addingTimeInterval(-8 * 3600),
            fixtures: [makeFixture(id: "played", leagueId: leagueId, start: kickoff, state: .scheduled)]
        )
        store.update(stale, for: leagueId)
        let service = SportsSyncService(
            store: store,
            followSource: StubFollowSource(leagues: [leagueId]),
            defaults: isolatedDefaults()
        )
        service.configure(provider: StubProvider())

        await service.catchUp()

        #expect(store.snapshot(for: leagueId)?.fixtures.count == 1)
        #expect(store.snapshot(for: leagueId)?.fixtures.first?.status.state == .scheduled)
    }
}

// MARK: - Filling leagues with nothing cached

/// `refreshMissing` is what puts fixtures on the Home rail when the schedule says
/// nothing is due — a followed league with an empty (or purged) cache. Its retry
/// rule is the part that matters: a pass the provider never answered must stay
/// eligible, or one offline launch leaves the rail blank until the viewer finds
/// Settings › Sports › Refresh Now.
@MainActor
struct SportsFillMissingTests {
    private let leagueId = "espn:soccer/ger.1"

    private func tempStore() -> SportsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SportsStore(cache: SportsCacheStore(directory: dir))
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "sports.test." + UUID().uuidString)!
    }

    private func service(store: SportsStore) -> SportsSyncService {
        SportsSyncService(
            store: store,
            followSource: StubFollowSource(leagues: [leagueId]),
            defaults: isolatedDefaults()
        )
    }

    @Test func `a followed league with nothing cached is filled`() async {
        let store = tempStore()
        let sync = service(store: store)
        sync.configure(provider: StubProvider(
            monthFixtures: [makeFixture(id: "1", leagueId: leagueId, start: Date(), state: .scheduled)]
        ))

        await sync.fillMissing()

        #expect(store.snapshot(for: leagueId)?.fixtures.count == 1)
    }

    @Test func `a league that answered is not fetched twice, even with no fixtures`() async {
        let store = tempStore()
        let counter = RequestCounter()
        let sync = service(store: store)
        // Off-season: no fixtures, but the provider is reachable and answers with
        // standings — that is a successful pass, not a failed one.
        sync.configure(provider: StubProvider(
            standingRows: [SportsStandingRow(id: "132", teamId: "132", name: "Bayern", rank: 1, points: 10)],
            monthCalls: counter
        ))

        await sync.fillMissing()
        await sync.fillMissing()

        #expect(counter.count == 1)
    }

    @Test func `a fill the provider never answered is retried`() async {
        let store = tempStore()
        let sync = service(store: store)
        // First pass: ESPN unreachable, everything degrades to empty.
        sync.configure(provider: StubProvider())
        await sync.fillMissing()
        #expect(store.snapshot(for: leagueId)?.fixtures.isEmpty ?? true)
        #expect(store.refreshError == true)

        // Second pass, provider back: the league must not have been struck off.
        sync.configure(provider: StubProvider(
            monthFixtures: [makeFixture(id: "1", leagueId: leagueId, start: Date(), state: .scheduled)]
        ))
        await sync.fillMissing()

        #expect(store.snapshot(for: leagueId)?.fixtures.count == 1)
        #expect(store.refreshError == false)
    }

    @Test func `a league already holding fixtures is left alone`() async {
        let store = tempStore()
        let counter = RequestCounter()
        store.update(
            SportsLeagueSnapshot(fixtures: [makeFixture(id: "cached", leagueId: leagueId, start: Date(), state: .scheduled)]),
            for: leagueId
        )
        let sync = service(store: store)
        sync.configure(provider: StubProvider(monthCalls: counter))

        await sync.fillMissing()

        #expect(counter.count == 0)
    }
}

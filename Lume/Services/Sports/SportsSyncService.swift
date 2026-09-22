//
//  SportsSyncService.swift
//  Lume
//
//  Owns the Sports Hub's background refresh and its live-score polling, mirroring
//  `EPGSyncService`/`SyncFrequency`: `configure` once, `syncIfDue()` from launch
//  and foreground, `syncNow()` for a manual pull.
//
//  Three refresh shapes, cheapest last:
//  - the scheduled refresh (`syncIfDue`): whole months plus teams and standings,
//    at most once per `SyncFrequency` interval;
//  - the catch-up (`catchUpIfStale`): today and yesterday by day, whenever the
//    newest snapshot is older than `catchUpStaleness` — how a rail opened in the
//    evening stops showing the morning's "15:30" on a game long over;
//  - the live poll (`beginLivePolling`): the days of every live or overdue
//    fixture, every 60 s while a sports surface is on screen.
//
//  A refresh hits ESPN (not the provider host), so the one-connection account cap
//  that gates `EPGSyncService` does not apply here — the two never compete. The
//  fetching runs on a utility Task; only the finished, `Sendable` snapshots cross
//  back to `SportsStore` on the main actor. A failure leaves the previous snapshot
//  in place and flags `SportsStore.refreshError` rather than blanking the hub.
//

import Foundation
import Observation
import OSLog
#if os(iOS)
    import UIKit
#endif

// MARK: - Follow source

/// The set of leagues and teams the active profile follows. `SportsFollowService`
/// (the per-profile iCloud mirror) is the production source, injected from
/// `LumeApp` via `configure(followSource:)`; tests supply stubs.
nonisolated protocol SportsFollowSource: Sendable {
    var followedLeagueIds: [String] { get }
    var followedTeamIds: [String] { get }
}

/// Follows nothing. The default until `configure(followSource:)` runs, so the
/// shared instance is inert rather than refreshing leagues nobody follows.
nonisolated struct EmptySportsFollowSource: SportsFollowSource {
    var followedLeagueIds: [String] {
        []
    }

    var followedTeamIds: [String] {
        []
    }
}

// MARK: - Sync service

@Observable
final class SportsSyncService {
    static let shared = SportsSyncService()

    private(set) var isSyncing = false

    private var provider: (any SportsDataProvider)?
    private var followSource: any SportsFollowSource
    private let store: SportsStore
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var missingTask: Task<Void, Never>?
    private var catchUpTask: Task<Void, Never>?
    /// Leagues `refreshMissing()` already filled this launch — only the ones the
    /// provider actually answered for, so an off-season league with genuinely no
    /// fixtures is not re-fetched on every appearance while a league that failed
    /// stays eligible for the next try.
    private var attemptedMissing: Set<String> = []

    /// Whether the app is foregrounded, updated from the scene-phase hook. Live
    /// polling pauses while the app is not active; coming back to the foreground
    /// catches the snapshots up, so hours in the background never leave a game
    /// "live" on the rail.
    var isForeground = true {
        didSet {
            if isForeground, !oldValue { catchUpIfStale() }
        }
    }

    private var liveTask: Task<Void, Never>?
    private var liveClients = 0

    /// `@AppStorage` key for the sports refresh interval — independent of the
    /// content-sync and EPG frequencies.
    static let syncFrequencyKey = "sports.syncFrequency"
    /// `@AppStorage` key for the Sports tab toggle.
    static let tabEnabledKey = "sports.tabEnabled"
    /// Default for the Sports tab toggle: on everywhere except iPhone, where iOS
    /// fits four regular tabs plus the Search pill — a fifth would push both
    /// Sports and Search into "More". There the Home rail's "See All" opens the
    /// hub and the tab can be enabled in Settings › Sports.
    static var tabEnabledDefault: Bool {
        #if os(iOS)
            UIDevice.current.userInterfaceIdiom != .phone
        #else
            true
        #endif
    }

    /// Sports data changes often; default to a daily refresh.
    static let defaultFrequency: SyncFrequency = .daily
    private static let lastRefreshKey = "lume.sportsLastRefresh"

    /// Teams (crests, colours) change rarely; reuse the cached roster for a week.
    private static let teamCacheLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// How often live scores re-poll while a sports surface is visible.
    static let livePollInterval: TimeInterval = 60
    /// How old the newest snapshot may be before a surface appearing (or the app
    /// foregrounding) re-fetches today and yesterday by day.
    static let catchUpStaleness: TimeInterval = 15 * 60
    /// How far back a fixture still called "scheduled" or "live" past its kickoff
    /// keeps the poll going. Beyond this the scheduled month refresh owns it; the
    /// bound keeps a fixture the provider dropped from polling forever.
    static let overdueLookback: TimeInterval = 3 * 24 * 60 * 60
    /// How many leagues refresh at once — ESPN, not the capped provider host.
    private static let maxConcurrentLeagueRefreshes = 4

    init(
        store: SportsStore = .shared,
        followSource: any SportsFollowSource = EmptySportsFollowSource(),
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.followSource = followSource
        self.defaults = defaults
    }

    /// Wires the data source and the follow service. Warms the store from disk
    /// so the hub renders before the first network refresh.
    func configure(
        provider: any SportsDataProvider = ESPNClient.shared,
        followSource: (any SportsFollowSource)? = nil
    ) {
        self.provider = provider
        if let followSource { self.followSource = followSource }
        store.loadCached(leagueIds: leaguesToRefresh())
    }

    // MARK: - Triggers

    /// Manual pull (a "Refresh" affordance): refreshes now regardless of the
    /// schedule.
    func syncNow() {
        kick()
    }

    /// Launch / foreground trigger: refreshes only if the sports data is stale per
    /// the sports frequency setting.
    func syncIfDue() {
        guard isDue else { return }
        kick()
    }

    /// Fetches followed leagues that have no fixtures yet — a league followed a
    /// moment ago must not wait for the next scheduled refresh to show up.
    func refreshMissing() {
        guard provider != nil, missingTask == nil else { return }
        guard !missingLeagueIds().isEmpty else { return }
        isSyncing = true
        missingTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await fillMissing()
            missingTask = nil
            isSyncing = task != nil
        }
    }

    /// One pass over the followed leagues that have nothing cached. Awaitable so
    /// tests can sequence on it; `refreshMissing()` wraps it in the
    /// fire-and-forget Task.
    func fillMissing() async {
        let missing = missingLeagueIds()
        guard !missing.isEmpty else { return }
        let refreshed = await performRefresh(leagueIds: missing, months: Self.monthsToFetch(for: Date()))
        // Only a league the provider actually answered for is struck off. An
        // off-season league with genuinely no fixtures still answers (its teams
        // and standings arrive), so it is not re-fetched on every appearance;
        // a league that answered nothing was a failure — one offline launch
        // must not leave the Home rail empty for the rest of the session.
        // A league the catalogue doesn't know can never answer, so it is struck
        // off too rather than retried forever.
        attemptedMissing.formUnion(refreshed)
        attemptedMissing.formUnion(missing.filter { SportsCatalog.league(id: $0) == nil })
    }

    /// Followed leagues with no cached fixtures that this launch has not already
    /// filled. Warms the store from disk first, so a league whose snapshot is
    /// merely not loaded yet is never re-fetched.
    private func missingLeagueIds() -> [String] {
        let ids = leaguesToRefresh()
        store.loadCached(leagueIds: ids)
        return ids.filter { id in
            !attemptedMissing.contains(id) && (store.snapshot(for: id)?.fixtures.isEmpty ?? true)
        }
    }

    /// Surface-appear / foreground trigger: re-fetches today and yesterday by day
    /// for every followed league when the newest snapshot is older than
    /// `catchUpStaleness`. Independent of the `SyncFrequency` schedule, which
    /// only says how often the whole month is re-pulled — and a daily pull done
    /// at 09:00 leaves every kickoff after it stale until tomorrow.
    func catchUpIfStale() {
        // A scheduled refresh in flight is about to bring the whole month; a day
        // fetch on top of it would only duplicate the requests.
        guard provider != nil, catchUpTask == nil, task == nil else { return }
        let ids = leaguesToRefresh()
        guard !ids.isEmpty else { return }
        store.loadCached(leagueIds: ids)
        guard Self.needsCatchUp(newestFetch: store.newestFetch(for: ids), now: Date()) else { return }
        catchUpTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await catchUp()
            catchUpTask = nil
        }
    }

    /// One catch-up pass over the followed leagues. Awaitable so tests can
    /// sequence on it; `catchUpIfStale()` wraps it with the staleness check.
    func catchUp() async {
        let ids = leaguesToRefresh()
        guard !ids.isEmpty else { return }
        let now = Date()
        let days = Self.catchUpDays(fixtures: store.fixtures(inLeagues: ids), now: now)
        await refreshDays(leagueIds: ids, days: days)
    }

    private var isDue: Bool {
        let raw = defaults.string(forKey: Self.syncFrequencyKey) ?? ""
        let frequency = SyncFrequency(rawValue: raw) ?? Self.defaultFrequency
        return frequency.isDue(lastSyncDate: lastRefreshDate)
    }

    /// The last successful refresh timestamp, for display in Settings. `nil` until
    /// the first successful refresh.
    var lastRefresh: Date? {
        lastRefreshDate
    }

    private var lastRefreshDate: Date? {
        get {
            let stamp = defaults.double(forKey: Self.lastRefreshKey)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set {
            defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.lastRefreshKey)
        }
    }

    private func kick() {
        guard provider != nil, task == nil else { return }
        guard !leaguesToRefresh().isEmpty else { return }
        isSyncing = true
        task = Task(priority: .utility) { [weak self] in
            await self?.refreshAll()
            self?.isSyncing = false
            self?.task = nil
        }
    }

    /// One full refresh over the followed leagues. Awaitable so callers (and tests)
    /// can sequence work after it; `kick()` wraps it in the fire-and-forget Task.
    func refreshAll() async {
        let leagueIds = leaguesToRefresh()
        guard !leagueIds.isEmpty else { return }
        await performRefresh(leagueIds: leagueIds, months: Self.monthsToFetch(for: Date()))
    }

    // MARK: - Live scores

    /// Called by a sports surface (tab / rail / detail) as it appears. Reference
    /// counted, so overlapping surfaces keep one shared 60s loop alive.
    func beginLivePolling() {
        liveClients += 1
        startLiveLoopIfNeeded()
    }

    /// Called as a sports surface disappears; the loop stops when the last one goes.
    func endLivePolling() {
        liveClients = max(0, liveClients - 1)
        if liveClients == 0 {
            liveTask?.cancel()
            liveTask = nil
        }
    }

    private func startLiveLoopIfNeeded() {
        guard liveTask == nil, liveClients > 0 else { return }
        liveTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self, liveClients > 0 else { break }
                if isForeground, !ContentIndexingService.shared.isPlaybackActive {
                    let ids = leaguesToRefresh()
                    let days = Self.pollDays(fixtures: store.fixtures(inLeagues: ids), now: Date())
                    if !days.isEmpty {
                        await refreshDays(leagueIds: ids, days: days)
                    }
                }
                try? await Task.sleep(for: .seconds(Self.livePollInterval))
            }
            self?.liveTask = nil
        }
    }

    /// A game is worth polling while the snapshot calls it live — or still
    /// "scheduled" for a kickoff that has passed, which is what a stale snapshot
    /// looks like once the day's games have started. Both are bounded by
    /// `overdueLookback`: a game "live" since last night is polled (and its own
    /// day fetched) until the provider closes it out; one from last week is
    /// left to the scheduled refresh.
    nonisolated static func isOverdue(_ fixture: SportsFixture, now: Date) -> Bool {
        switch fixture.status.state {
        case .inProgress, .scheduled:
            fixture.startDate <= now && fixture.startDate > now.addingTimeInterval(-overdueLookback)
        case .final, .postponed:
            false
        }
    }

    /// Whether a catch-up is worth a request: no snapshot yet, or the newest one
    /// is older than `catchUpStaleness`.
    nonisolated static func needsCatchUp(newestFetch: Date?, now: Date) -> Bool {
        guard let newestFetch else { return true }
        return now.timeIntervalSince(newestFetch) > catchUpStaleness
    }

    /// The calendar days the live poll fetches: the day of every overdue fixture.
    /// Empty when nothing is live or overdue, so an idle hub costs no requests.
    /// Sorted and unique so a day is never fetched twice per pass.
    nonisolated static func pollDays(fixtures: [SportsFixture], now: Date, calendar: Calendar = .current) -> [Date] {
        let overdue = fixtures.lazy.filter { isOverdue($0, now: now) }.map { calendar.startOfDay(for: $0.startDate) }
        return Array(Set(overdue)).sorted()
    }

    /// The calendar days a catch-up fetches: today, yesterday (late games ending
    /// after midnight, and time zones where the provider's day differs from the
    /// viewer's) and the day of every overdue fixture.
    nonisolated static func catchUpDays(fixtures: [SportsFixture], now: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        var days: Set<Date> = [today]
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            days.insert(yesterday)
        }
        days.formUnion(pollDays(fixtures: fixtures, now: now, calendar: calendar))
        return days.sorted()
    }

    // MARK: - Refresh

    /// Refreshes the given leagues and returns the ids that actually came back
    /// with something — the caller's evidence of which fetches succeeded, as
    /// opposed to which were merely attempted.
    @discardableResult
    private func performRefresh(leagueIds: [String], months: [DateComponents]) async -> Set<String> {
        let leagues = leagueIds.compactMap { SportsCatalog.league(id: $0) }
        let refreshed = await withTaskGroup(of: (String, Bool).self) { group in
            var iterator = leagues.makeIterator()
            for _ in 0 ..< Self.maxConcurrentLeagueRefreshes {
                guard let league = iterator.next() else { break }
                group.addTask { await (league.id, self.refreshLeague(league, months: months)) }
            }
            var succeeded: Set<String> = []
            while let (leagueId, success) = await group.next() {
                if success { succeeded.insert(leagueId) }
                if let league = iterator.next() {
                    group.addTask { await (league.id, self.refreshLeague(league, months: months)) }
                }
            }
            return succeeded
        }
        if refreshed.isEmpty {
            store.markRefreshFailed()
        } else {
            lastRefreshDate = Date()
        }
        return refreshed
    }

    /// Fetches one league's months, teams (reusing the weekly roster cache) and
    /// standings, then publishes a merged snapshot. Returns whether anything fresh
    /// arrived; on a total failure it leaves the existing snapshot untouched.
    private func refreshLeague(_ league: SportsLeague, months: [DateComponents]) async -> Bool {
        guard let provider else { return false }
        let existing = store.snapshot(for: league.id)
        let teamsCacheFresh = Self.teamsCacheIsFresh(existing)

        async let fetchedMonths = Self.fetchFixtures(provider: provider, league: league, months: months)
        async let fetchedTeams = teamsCacheFresh ? [] : ((try? provider.teams(league: league)) ?? [])
        async let fetchedStandings = (try? provider.standings(league: league)) ?? []

        let (monthFixtures, gotFixtures) = await fetchedMonths
        let teamsResult = await fetchedTeams
        let standingsResult = await fetchedStandings

        var fixturesById: [String: SportsFixture] = [:]
        if let existing {
            for fixture in existing.fixtures {
                fixturesById[fixture.id] = fixture
            }
        }
        for fixture in monthFixtures {
            fixturesById[fixture.id] = fixture
        }

        let teams: [SportsTeam]
        let teamsFetchedAt: Date?
        var gotTeams = false
        if teamsCacheFresh {
            teams = existing?.teams ?? []
            teamsFetchedAt = existing?.teamsFetchedAt
        } else if teamsResult.isEmpty {
            teams = existing?.teams ?? []
            teamsFetchedAt = existing?.teamsFetchedAt
        } else {
            teams = teamsResult
            teamsFetchedAt = Date()
            gotTeams = true
        }

        let standings = standingsResult.isEmpty ? (existing?.standings ?? []) : standingsResult

        guard gotFixtures || gotTeams || !standingsResult.isEmpty else { return false }

        let snapshot = SportsLeagueSnapshot(
            fetchedAt: Date(),
            fixtures: Array(fixturesById.values),
            standings: standings,
            teams: teams,
            teamsFetchedAt: teamsFetchedAt
        )
        store.update(snapshot, for: league.id)
        return true
    }

    /// Whether the cached roster is present and still within its week-long life.
    private nonisolated static func teamsCacheIsFresh(_ existing: SportsLeagueSnapshot?) -> Bool {
        guard let existing, !existing.teams.isEmpty, let fetchedAt = existing.teamsFetchedAt else {
            return false
        }
        return Date().timeIntervalSince(fetchedAt) < teamCacheLifetime
    }

    /// Fetches a league's months concurrently and merges them in month order, so
    /// per-league latency is the slowest month rather than their sum.
    private nonisolated static func fetchFixtures(
        provider: any SportsDataProvider,
        league: SportsLeague,
        months: [DateComponents]
    ) async -> (fixtures: [SportsFixture], gotAny: Bool) {
        await withTaskGroup(of: (Int, [SportsFixture]).self) { group in
            for (index, month) in months.enumerated() {
                group.addTask {
                    await (index, (try? provider.fixtures(league: league, month: month)) ?? [])
                }
            }
            var byIndex: [Int: [SportsFixture]] = [:]
            for await (index, fetched) in group {
                byIndex[index] = fetched
            }
            var all: [SportsFixture] = []
            var gotAny = false
            for index in months.indices {
                let fetched = byIndex[index] ?? []
                if !fetched.isEmpty { gotAny = true }
                all.append(contentsOf: fetched)
            }
            return (all, gotAny)
        }
    }

    /// Re-fetches the given days by day for every league and merges the fresh
    /// fixtures into each league's snapshot, leaving the rest of the month intact.
    /// Shared by the live poll and the catch-up; a league whose every day came
    /// back empty is left untouched (that is what a failed request looks like).
    private func refreshDays(leagueIds: [String], days: [Date]) async {
        guard let provider, !days.isEmpty else { return }
        let leagues = leagueIds.compactMap { SportsCatalog.league(id: $0) }
        let fetchedByLeague = await withTaskGroup(of: (String, [SportsFixture]).self) { group in
            for league in leagues {
                for day in days {
                    group.addTask {
                        await (league.id, (try? provider.fixtures(league: league, day: day)) ?? [])
                    }
                }
            }
            var out: [String: [SportsFixture]] = [:]
            for await (leagueId, fixtures) in group {
                out[leagueId, default: []].append(contentsOf: fixtures)
            }
            return out
        }

        var updated = false
        for (leagueId, fetched) in fetchedByLeague {
            guard !fetched.isEmpty else { continue }
            var snapshot = store.snapshot(for: leagueId) ?? SportsLeagueSnapshot()
            var byId = Dictionary(snapshot.fixtures.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for fixture in fetched {
                byId[fixture.id] = fixture
            }
            snapshot.fixtures = Array(byId.values)
            snapshot.fetchedAt = Date()
            store.update(snapshot, for: leagueId)
            updated = true
        }
        if updated { store.noteLiveScoreUpdate() }
    }

    // MARK: - Helpers

    /// The union of followed leagues and the leagues of followed teams, in follow
    /// order with duplicates removed.
    func leaguesToRefresh() -> [String] {
        var ids: [String] = []
        var seen: Set<String> = []
        for leagueId in followSource.followedLeagueIds where seen.insert(leagueId).inserted {
            ids.append(leagueId)
        }
        for teamId in followSource.followedTeamIds {
            guard let leagueId = Self.leagueId(fromTeamID: teamId) else { continue }
            if seen.insert(leagueId).inserted { ids.append(leagueId) }
        }
        return ids
    }

    /// The league id embedded in a team id ("espn:soccer/ger.1:132" → "espn:soccer/ger.1").
    nonisolated static func leagueId(fromTeamID teamID: String) -> String? {
        guard let range = teamID.range(of: ":", options: .backwards) else { return nil }
        return String(teamID[..<range.lowerBound])
    }

    /// The calendar months a refresh should fetch: the current month, plus the
    /// next month when the date is within 7 days of the current month's end (so a
    /// fixture list never runs dry at a month boundary). Pure, so it is unit-tested.
    nonisolated static func monthsToFetch(for date: Date, calendar: Calendar = .current) -> [DateComponents] {
        let current = calendar.dateComponents([.year, .month], from: date)
        var months = [current]
        let day = calendar.component(.day, from: date)
        if let range = calendar.range(of: .day, in: .month, for: date),
           range.count - day <= 7,
           let nextMonth = calendar.date(byAdding: .month, value: 1, to: date)
        {
            months.append(calendar.dateComponents([.year, .month], from: nextMonth))
        }
        return months
    }
}

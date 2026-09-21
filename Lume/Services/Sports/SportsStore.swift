//
//  SportsStore.swift
//  Lume
//
//  The in-memory home of the Sports Hub's cached data: one `SportsLeagueSnapshot`
//  per league, published to the UI. It is the single source every sports surface
//  reads — never `@Query` (there is no SwiftData model for sports) and never the
//  network directly. `SportsSyncService` fills it; views observe it.
//
//  `@MainActor @Observable` so SwiftUI observes its mutations; the actual fetching
//  happens off-main in the sync service and only the finished, `Sendable`
//  snapshots cross back here.
//

import Foundation
import Observation

@MainActor
@Observable
final class SportsStore {
    static let shared = SportsStore()

    /// Cached snapshots keyed by league id ("espn:{sport}/{slug}").
    private(set) var snapshots: [String: SportsLeagueSnapshot] = [:]

    /// When the last successful refresh published new data.
    private(set) var lastRefresh: Date?

    /// True when the most recent refresh failed outright (network down, ESPN
    /// unreachable). The hub degrades to whatever snapshots are already loaded and
    /// shows a subtle "Scores unavailable" note rather than a blank screen.
    var refreshError = false

    /// Bumped after every live-score poll so views showing in-progress fixtures
    /// re-read scores even when the fixture ids are unchanged.
    private(set) var liveScoreTick = 0

    private let cache: SportsCacheStore

    init(cache: SportsCacheStore = SportsCacheStore()) {
        self.cache = cache
    }

    // MARK: - Loading

    /// Warms `snapshots` from disk for the given leagues so the hub renders
    /// immediately (and offline) before the first network refresh returns.
    func loadCached(leagueIds: [String]) {
        for leagueId in leagueIds where snapshots[leagueId] == nil {
            if let snapshot = cache.load(leagueId: leagueId) {
                snapshots[leagueId] = snapshot
            }
        }
    }

    // MARK: - Writing

    /// Replaces a league's snapshot in memory and on disk, and marks the store
    /// fresh. Called on the main actor by the sync service with a finished value.
    func update(_ snapshot: SportsLeagueSnapshot, for leagueId: String) {
        snapshots[leagueId] = snapshot
        cache.save(snapshot, for: leagueId)
        lastRefresh = Date()
        refreshError = false
    }

    /// Merges a freshly fetched team roster into a league's snapshot (crests and
    /// colours only), leaving fixtures and standings untouched and without
    /// flipping the refresh state — used by the browse picker's on-demand team
    /// fetch for a league that has not been refreshed yet.
    func mergeTeams(_ teams: [SportsTeam], for leagueId: String) {
        guard !teams.isEmpty else { return }
        var snapshot = snapshots[leagueId] ?? SportsLeagueSnapshot()
        snapshot.teams = teams
        snapshot.teamsFetchedAt = Date()
        snapshots[leagueId] = snapshot
        cache.save(snapshot, for: leagueId)
    }

    func noteLiveScoreUpdate() {
        liveScoreTick += 1
    }

    func markRefreshFailed() {
        refreshError = true
    }

    // MARK: - Derived reads

    func snapshot(for leagueId: String) -> SportsLeagueSnapshot? {
        snapshots[leagueId]
    }

    /// Every cached fixture of the given leagues, in no particular order — the
    /// input to the sync service's overdue and catch-up day calculations.
    func fixtures(inLeagues leagueIds: [String]) -> [SportsFixture] {
        leagueIds.flatMap { snapshots[$0]?.fixtures ?? [] }
    }

    /// When the most recently fetched of the given leagues' snapshots was
    /// written; `nil` when none of them is loaded. What the catch-up compares
    /// against `SportsSyncService.catchUpStaleness`.
    func newestFetch(for leagueIds: [String]) -> Date? {
        leagueIds.compactMap { snapshots[$0]?.fetchedAt }.max()
    }

    /// Every cached fixture that kicks off on the given calendar day, across all
    /// loaded leagues, sorted by start time.
    func fixtures(for day: Date, calendar: Calendar = .current) -> [SportsFixture] {
        snapshots.values
            .flatMap(\.fixtures)
            .filter { calendar.isDate($0.startDate, inSameDayAs: day) }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Looks a team up by its full id ("espn:{sport}/{slug}:{teamId}") or, as a
    /// fallback, by the raw provider team id carried on standings rows.
    func team(by id: String) -> SportsTeam? {
        for snapshot in snapshots.values {
            if let match = snapshot.teams.first(where: { $0.id == id || $0.teamId == id }) {
                return match
            }
        }
        return nil
    }

    /// The team's colour pair for card tints and gradients, resolved from the
    /// teams cache. `nil` when the team is not cached yet.
    func palette(for teamId: String) -> SportsTeamColors? {
        guard let team = team(by: teamId) else { return nil }
        return SportsTeamColors(primaryHex: team.colorHex, alternateHex: team.alternateColorHex)
    }

    /// True when there is no data, or the newest snapshot is old enough that a
    /// refresh is worth showing an "updating" affordance for.
    var isStale: Bool {
        guard let lastRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) > Self.staleThreshold
    }

    private static let staleThreshold: TimeInterval = 15 * 60
}

/// A team's raw colour hexes (no leading `#`), provider-neutral so the view layer
/// can build its `TeamPalette` (contrast floor, dark-mode handling) from it.
nonisolated struct SportsTeamColors: Hashable {
    let primaryHex: String?
    let alternateHex: String?
}

nonisolated extension SportsFixture {
    /// Whether the fixture is currently being played — the signal live-score
    /// polling keys off.
    var isInProgress: Bool {
        status.state == .inProgress
    }

    /// The order every fixture list shows: live games first, then upcoming by
    /// kickoff, then finished ones (most recent first). Ties fall back to the
    /// league and the fixture id so equal kickoffs never reshuffle between
    /// renders — a dictionary-backed list otherwise changes order on its own.
    static func displayOrder(_ lhs: SportsFixture, _ rhs: SportsFixture) -> Bool {
        if lhs.displayStatusRank != rhs.displayStatusRank { return lhs.displayStatusRank < rhs.displayStatusRank }
        if lhs.startDate != rhs.startDate {
            // Finished games read newest-first; everything else chronologically.
            return lhs.displayStatusRank == 2 ? lhs.startDate > rhs.startDate : lhs.startDate < rhs.startDate
        }
        if lhs.leagueId != rhs.leagueId { return lhs.leagueId < rhs.leagueId }
        return lhs.id < rhs.id
    }

    /// 0 live, 1 upcoming (or postponed), 2 finished — the coarse key of `displayOrder`.
    var displayStatusRank: Int {
        switch status.state {
        case .inProgress: 0
        case .scheduled, .postponed: 1
        case .final: 2
        }
    }
}

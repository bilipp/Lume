//
//  SportsRailPlanner.swift
//  Lume
//
//  The one rule for what the Home Sports rail shows: followed teams' fixtures
//  first, then followed leagues', within today-and-the-next-week (plus anything
//  in progress), de-duplicated and capped so the shelf stays a shelf. Shared by
//  the phone/desktop rail, the tvOS rail and HomeView's empty-state check so
//  the three never disagree about whether the rail has content.
//

import Foundation

enum SportsRailPlanner {
    /// How many cards the shelf shows at most.
    static let maxFixtures = 20

    /// The league ids whose snapshots feed the rail: every followed league plus
    /// the league of every followed team, in follow order.
    static func displayLeagueIds(for follows: [SportsFollow]) -> [String] {
        var result: [String] = []
        for follow in follows {
            let leagueId = follow.kind == .league
                ? follow.key
                : SportsHubView.leagueId(fromTeamKey: follow.key)
            if let leagueId, !result.contains(leagueId) { result.append(leagueId) }
        }
        return result
    }

    static func fixtures(follows: [SportsFollow], store: SportsStore, now: Date = Date()) -> [SportsFixture] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let followedTeamKeys = Set(follows.filter { $0.kind == .team }.map(\.key))
        let followedLeagueKeys = Set(follows.filter { $0.kind == .league }.map(\.key))

        var teamFixtures: [SportsFixture] = []
        var leagueFixtures: [SportsFixture] = []
        var seen: Set<String> = []

        for leagueId in displayLeagueIds(for: follows) {
            guard let snapshot = store.snapshot(for: leagueId) else { continue }
            let leagueFollowed = followedLeagueKeys.contains(leagueId)
            for fixture in snapshot.fixtures.flatMap({ $0.expandedBySession(now: now) })
                where isInWindow(fixture, start: start, end: end)
            {
                if involvesFollowedTeam(fixture, followedTeamKeys: followedTeamKeys) {
                    if seen.insert(fixture.id).inserted { teamFixtures.append(fixture) }
                } else if leagueFollowed {
                    if seen.insert(fixture.id).inserted { leagueFixtures.append(fixture) }
                }
            }
        }

        // Live → upcoming → finished across the whole rail; within a state the
        // followed teams' games lead the followed leagues' games.
        let teamIDs = Set(teamFixtures.map(\.id))
        let ordered = (teamFixtures + leagueFixtures).sorted { lhs, rhs in
            if lhs.displayStatusRank != rhs.displayStatusRank { return lhs.displayStatusRank < rhs.displayStatusRank }
            let lhsTeam = teamIDs.contains(lhs.id), rhsTeam = teamIDs.contains(rhs.id)
            if lhsTeam != rhsTeam { return lhsTeam }
            return SportsFixture.displayOrder(lhs, rhs)
        }
        return Array(ordered.prefix(maxFixtures))
    }

    /// Whether the rail renders anything for this viewer: free users get the
    /// locked row, premium users the onboarding card when
    /// nothing is followed, otherwise cards only when there are fixtures.
    static func hasContent(isPremium: Bool, follows: [SportsFollow], store: SportsStore, lockedRowShown: Bool) -> Bool {
        guard isPremium else { return lockedRowShown }
        return follows.isEmpty || hasAnyFixture(follows: follows, store: store)
    }

    /// Whether at least one followed fixture falls in the rail's window, without
    /// building or sorting the capped list — the cheap probe `hasContent` needs.
    static func hasAnyFixture(follows: [SportsFollow], store: SportsStore, now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let followedTeamKeys = Set(follows.filter { $0.kind == .team }.map(\.key))
        let followedLeagueKeys = Set(follows.filter { $0.kind == .league }.map(\.key))

        for leagueId in displayLeagueIds(for: follows) {
            guard let snapshot = store.snapshot(for: leagueId) else { continue }
            let leagueFollowed = followedLeagueKeys.contains(leagueId)
            for fixture in snapshot.fixtures.flatMap({ $0.expandedBySession(now: now) })
                where isInWindow(fixture, start: start, end: end)
            {
                if leagueFollowed || involvesFollowedTeam(fixture, followedTeamKeys: followedTeamKeys) {
                    return true
                }
            }
        }
        return false
    }

    private static func isInWindow(_ fixture: SportsFixture, start: Date, end: Date) -> Bool {
        fixture.isInProgress || (fixture.startDate >= start && fixture.startDate < end)
    }

    private static func involvesFollowedTeam(_ fixture: SportsFixture, followedTeamKeys: Set<String>) -> Bool {
        if let home = fixture.home?.team, followedTeamKeys.contains(home.id) { return true }
        if let away = fixture.away?.team, followedTeamKeys.contains(away.id) { return true }
        return false
    }
}

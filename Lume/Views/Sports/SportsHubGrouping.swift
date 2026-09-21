//
//  SportsHubGrouping.swift
//  Lume
//
//  The one set of rules for which fixtures a Sports Hub scope + segment shows and
//  how they group into sections. The phone `SportsHubView` and the tvOS
//  `TVSportsHubScreen` both delegate here so the two hubs never disagree, leaving
//  each screen only its own chrome.
//

import Foundation

@MainActor
struct SportsHubGrouping {
    let scope: SportsHubScope
    let segment: SportsHubSegment
    let follows: [SportsFollow]
    let store: SportsStore
    var now: Date = .init()

    /// The league ids the current scope draws from: one for a league scope, or
    /// every followed league plus the league of each followed team (deduped,
    /// order-preserving) for My Teams.
    var displayLeagueIds: [String] {
        if case let .league(id) = scope { return [id] }
        return SportsRailPlanner.displayLeagueIds(for: follows)
    }

    /// Every followed league (plus followed teams' leagues) regardless of the
    /// current scope — this feeds the scope menu, which must always offer the
    /// full list, not just the league currently selected.
    var followedLeagues: [SportsLeague] {
        SportsRailPlanner.displayLeagueIds(for: follows).compactMap { SportsCatalog.league(id: $0) }
    }

    var followedTeamKeys: Set<String> {
        Set(follows.filter { $0.kind == .team }.map(\.key))
    }

    var followedLeagueKeys: Set<String> {
        Set(follows.filter { $0.kind == .league }.map(\.key))
    }

    var scopeIsLeague: Bool {
        if case .league = scope { return true }
        return false
    }

    func involvesFollowedTeam(_ fixture: SportsFixture) -> Bool {
        if let home = fixture.home?.team, followedTeamKeys.contains(home.id) { return true }
        if let away = fixture.away?.team, followedTeamKeys.contains(away.id) { return true }
        return false
    }

    /// Every fixture on screen for the current scope + segment, deduped and sorted
    /// by kickoff. A league followed as a league contributes all of its fixtures; a
    /// league present only through a followed team contributes just that team's.
    var visibleFixtures: [SportsFixture] {
        let range = SportsHubView.dateRange(for: segment, now: now)
        var byID: [String: SportsFixture] = [:]
        for leagueId in displayLeagueIds {
            guard let snapshot = store.snapshot(for: leagueId) else { continue }
            let leagueFollowed = scopeIsLeague || followedLeagueKeys.contains(leagueId)
            // A race weekend becomes one card per session before the day filter,
            // so Saturday's race shows under Saturday, not under Thursday's practice.
            for fixture in snapshot.fixtures.flatMap({ $0.expandedBySession(now: now) })
                where range.contains(fixture.startDate)
            {
                if leagueFollowed || involvesFollowedTeam(fixture) {
                    byID[fixture.id] = fixture
                }
            }
        }
        return byID.values.sorted(by: SportsFixture.displayOrder)
    }

    /// The display groups the sections view renders. Upcoming groups by day;
    /// Today/Yesterday group by "My Teams" then followed league.
    var groups: [SportsFixtureGroup] {
        groups(for: visibleFixtures)
    }

    /// The display groups for an already-resolved fixture set, so a caller that has
    /// computed `visibleFixtures` once per render need not recompute it here.
    func groups(for fixtures: [SportsFixture]) -> [SportsFixtureGroup] {
        if segment == .upcoming {
            return SportsFixtureGroup.byDay(fixtures)
        }
        // Within a section `SportsFixture.displayOrder` already puts live games
        // first, upcoming next and finished last.
        if case let .league(leagueId) = scope {
            // The header carries the crest the cards drop, same as a league
            // cluster under My Teams; no chevron, since the hub is already scoped.
            let logoURL = fixtures.first?.leagueLogoURL ?? SportsCatalog.league(id: leagueId)?.logoURL
            return fixtures.isEmpty ? [] : [SportsFixtureGroup(
                id: "all", title: scopeTitle, logoURL: logoURL, leagueId: nil, fixtures: fixtures, isSingleLeague: true
            )]
        }
        return byMyTeamsAndLeague(fixtures)
    }

    private func byMyTeamsAndLeague(_ fixtures: [SportsFixture]) -> [SportsFixtureGroup] {
        var groups: [SportsFixtureGroup] = []
        let mine = fixtures.filter(involvesFollowedTeam)
        if !mine.isEmpty {
            groups.append(SportsFixtureGroup(
                id: "myTeams",
                title: String(localized: "★ My Teams"),
                logoURL: nil,
                leagueId: nil,
                fixtures: mine
            ))
        }
        let mineIDs = Set(mine.map(\.id))
        for league in followedLeagues where followedLeagueKeys.contains(league.id) {
            let leagueFixtures = fixtures.filter { $0.leagueId == league.id && !mineIDs.contains($0.id) }
            guard !leagueFixtures.isEmpty else { continue }
            groups.append(SportsFixtureGroup(
                id: league.id,
                title: league.name,
                logoURL: leagueFixtures.first?.leagueLogoURL ?? league.logoURL,
                leagueId: league.id,
                fixtures: leagueFixtures,
                isSingleLeague: true
            ))
        }
        return groups
    }

    /// Followed-team (or, failing that, followed-league) names for the "no games"
    /// state's chips.
    var emptyChips: [String] {
        let teams = follows
            .filter { $0.kind == .team }
            .compactMap { follow -> String? in
                let team = store.team(by: follow.key)
                return team?.shortName ?? team?.name
            }
        if !teams.isEmpty { return teams }
        return followedLeagues.map(\.name)
    }

    var scopeTitle: String {
        switch scope {
        case .myTeams:
            String(localized: "My Teams")
        case let .league(id):
            SportsCatalog.league(id: id)?.name ?? String(localized: "My Teams")
        }
    }
}

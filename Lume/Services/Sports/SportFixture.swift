//
//  SportFixture.swift
//  Lume
//
//  Value types describing the football data the Upcoming Matches feature works
//  with: a normalized fixture (one upcoming match) and a team the user can
//  follow. Both are `nonisolated` so the networking layer and the pure matcher
//  can pass them across actor boundaries.
//

import Foundation

/// A single upcoming match, normalized from the fixtures provider (TheSportsDB).
nonisolated struct SportFixture: Identifiable, Hashable {
    /// The provider's event id — stable, used to de-duplicate fixtures that come
    /// back from both a favorite league fetch and a favorite team fetch.
    let id: String
    let leagueID: String
    let leagueName: String
    let homeTeam: String
    let awayTeam: String
    let kickoff: Date
    let homeBadgeURL: URL?
    let awayBadgeURL: URL?
    let leagueBadgeURL: URL?

    init(
        id: String,
        leagueID: String,
        leagueName: String,
        homeTeam: String,
        awayTeam: String,
        kickoff: Date,
        homeBadgeURL: URL? = nil,
        awayBadgeURL: URL? = nil,
        leagueBadgeURL: URL? = nil
    ) {
        self.id = id
        self.leagueID = leagueID
        self.leagueName = leagueName
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.kickoff = kickoff
        self.homeBadgeURL = homeBadgeURL
        self.awayBadgeURL = awayBadgeURL
        self.leagueBadgeURL = leagueBadgeURL
    }

    /// "Home vs Away", the headline shown on the match card.
    var matchup: String {
        "\(homeTeam) vs \(awayTeam)"
    }
}

/// A football team the user can follow, from a league browse or a name search.
nonisolated struct SportTeam: Identifiable, Hashable {
    let id: String
    let name: String
    /// The team's league, shown as a subtitle to tell apart search hits like a
    /// senior side from its youth/reserve team.
    let leagueName: String?
    let badgeURL: URL?

    init(id: String, name: String, leagueName: String? = nil, badgeURL: URL? = nil) {
        self.id = id
        self.name = name
        self.leagueName = leagueName
        self.badgeURL = badgeURL
    }
}

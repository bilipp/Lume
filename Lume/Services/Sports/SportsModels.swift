//
//  SportsModels.swift
//  Lume
//
//  Provider-neutral value types for the Sports Hub. All are plain, `nonisolated`
//  value types (no SwiftData, no networking) so nonisolated providers, matchers
//  and caches can pass them freely under `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`.
//  Ids are provider-prefixed ("espn:{sport}/{slug}" for a league,
//  "espn:{sport}/{slug}:{teamId}" for a team) so follows and device-local channel
//  picks key off a stable, provider-neutral string.
//

import Foundation

// MARK: - League

nonisolated struct SportsLeague: Identifiable, Codable, Hashable {
    let id: String
    let sport: String
    let slug: String
    let name: String
    let abbreviation: String
    let logoURL: URL?
    let region: SportsRegion

    init(
        sport: String,
        slug: String,
        name: String,
        abbreviation: String,
        region: SportsRegion,
        logoURL: URL? = nil
    ) {
        id = SportsLeague.makeID(sport: sport, slug: slug)
        self.sport = sport
        self.slug = slug
        self.name = name
        self.abbreviation = abbreviation
        self.logoURL = logoURL
        self.region = region
    }

    static func makeID(sport: String, slug: String) -> String {
        "espn:\(sport)/\(slug)"
    }
}

nonisolated extension SportsLeague {
    /// A copy carrying the artwork resolved from a live API response.
    func withLogo(_ url: URL?) -> SportsLeague {
        SportsLeague(sport: sport, slug: slug, name: name, abbreviation: abbreviation, region: region, logoURL: url)
    }
}

// MARK: - Region grouping

/// Region buckets for the Manage Teams browser. Section titles are localised at
/// the view layer; the raw value is stable, non-user-facing data.
nonisolated enum SportsRegion: String, Codable, Hashable, CaseIterable {
    case europe
    case ukAndIreland
    case germany
    case spain
    case italy
    case france
    case americas
    case usLeagues
    case international
    case motorsport
    case combat
}

// MARK: - Team

nonisolated struct SportsTeam: Identifiable, Codable, Hashable {
    let id: String
    let leagueId: String
    let teamId: String
    let name: String
    let shortName: String
    let abbreviation: String
    let logoURL: URL?
    let darkLogoURL: URL?
    let colorHex: String?
    let alternateColorHex: String?

    init(
        leagueId: String,
        teamId: String,
        name: String,
        shortName: String,
        abbreviation: String,
        logoURL: URL? = nil,
        darkLogoURL: URL? = nil,
        colorHex: String? = nil,
        alternateColorHex: String? = nil
    ) {
        id = SportsTeam.makeID(leagueId: leagueId, teamId: teamId)
        self.leagueId = leagueId
        self.teamId = teamId
        self.name = name
        self.shortName = shortName
        self.abbreviation = abbreviation
        self.logoURL = logoURL
        self.darkLogoURL = darkLogoURL
        self.colorHex = colorHex
        self.alternateColorHex = alternateColorHex
    }

    /// `leagueId` already carries the "espn:{sport}/{slug}" prefix, so the team id
    /// is that league id plus ":{teamId}".
    static func makeID(leagueId: String, teamId: String) -> String {
        "\(leagueId):\(teamId)"
    }
}

// MARK: - Fixture

nonisolated enum SportsFixtureState: String, Codable, Hashable {
    case scheduled
    case inProgress
    case final
    case postponed
}

nonisolated struct SportsFixtureStatus: Codable, Hashable {
    let state: SportsFixtureState
    /// The provider's long form, e.g. "FT", "45'", "HT", or a kickoff date line.
    let detail: String
    let shortDetail: String

    init(state: SportsFixtureState, detail: String = "", shortDetail: String = "") {
        self.state = state
        self.detail = detail
        self.shortDetail = shortDetail
    }
}

nonisolated extension SportsFixtureStatus {
    /// The long-form detail line, falling back to the short form when the provider
    /// left it empty. Both game-detail sheets show it beside the league name.
    var displayDetail: String {
        detail.isEmpty ? shortDetail : detail
    }
}

nonisolated struct SportsCompetitor: Codable, Hashable {
    let team: SportsTeam
    let score: Int?
    let isWinner: Bool
    /// Recent-form string, e.g. "WWDWW".
    let form: String?
    /// Season record summary, e.g. "12-3-4".
    let record: String?

    init(team: SportsTeam, score: Int? = nil, isWinner: Bool = false, form: String? = nil, record: String? = nil) {
        self.team = team
        self.score = score
        self.isWinner = isWinner
        self.form = form
        self.record = record
    }
}

/// A weekend session for a race sport (F1): FP1/FP2/FP3/Qual/Race and its time.
nonisolated enum SportsSessionKind: String, Codable, Hashable {
    case fp1 = "FP1"
    case fp2 = "FP2"
    case fp3 = "FP3"
    case qualifying = "Qual"
    case race = "Race"
}

nonisolated struct SportsSession: Codable, Hashable {
    let kind: SportsSessionKind
    let date: Date
}

nonisolated struct SportsFixture: Identifiable, Codable, Hashable {
    let id: String
    let leagueId: String
    let leagueName: String
    let leagueAbbreviation: String
    let startDate: Date
    let status: SportsFixtureStatus
    /// `nil` for competitor-less events such as an F1 race weekend.
    let home: SportsCompetitor?
    let away: SportsCompetitor?
    let venue: String?
    let broadcasters: [String]
    /// Race-sport sessions; empty for team fixtures.
    let sessions: [SportsSession]

    init(
        id: String,
        leagueId: String,
        leagueName: String,
        leagueAbbreviation: String,
        startDate: Date,
        status: SportsFixtureStatus,
        home: SportsCompetitor? = nil,
        away: SportsCompetitor? = nil,
        venue: String? = nil,
        broadcasters: [String] = [],
        sessions: [SportsSession] = []
    ) {
        self.id = id
        self.leagueId = leagueId
        self.leagueName = leagueName
        self.leagueAbbreviation = leagueAbbreviation
        self.startDate = startDate
        self.status = status
        self.home = home
        self.away = away
        self.venue = venue
        self.broadcasters = broadcasters
        self.sessions = sessions
    }
}

// MARK: - Standings

nonisolated enum SportsStandingKind: String, Codable, Hashable {
    case team
    case driver
    case constructor
}

nonisolated struct SportsStandingRow: Identifiable, Codable, Hashable {
    /// The team id for team rows, or the athlete/constructor id for F1 rows.
    let id: String
    let kind: SportsStandingKind
    /// The team id for team-sport rows; `nil` for a driver standing.
    let teamId: String?
    /// Row label: team name, or driver/constructor name for F1.
    let name: String
    let rank: Int
    let played: Int?
    let wins: Int?
    let draws: Int?
    let losses: Int?
    let goalDifference: Int?
    let points: Int?
    /// Sport-specific extras keyed by stat name (e.g. NBA "streak", MLB "gb").
    let extra: [String: String]

    init(
        id: String,
        kind: SportsStandingKind = .team,
        teamId: String? = nil,
        name: String,
        rank: Int,
        played: Int? = nil,
        wins: Int? = nil,
        draws: Int? = nil,
        losses: Int? = nil,
        goalDifference: Int? = nil,
        points: Int? = nil,
        extra: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.teamId = teamId
        self.name = name
        self.rank = rank
        self.played = played
        self.wins = wins
        self.draws = draws
        self.losses = losses
        self.goalDifference = goalDifference
        self.points = points
        self.extra = extra
    }
}

// MARK: - Event detail

nonisolated struct SportsKeyEvent: Codable, Hashable {
    /// Match clock display, e.g. "45'+2" or "12:03".
    let clock: String
    /// Provider event text, e.g. "Goal", "Yellow Card".
    let type: String
    let teamId: String?
    let participants: [String]
    let isGoal: Bool
    let isCard: Bool
    let isSubstitution: Bool

    init(
        clock: String,
        type: String,
        teamId: String? = nil,
        participants: [String] = [],
        isGoal: Bool = false,
        isCard: Bool = false,
        isSubstitution: Bool = false
    ) {
        self.clock = clock
        self.type = type
        self.teamId = teamId
        self.participants = participants
        self.isGoal = isGoal
        self.isCard = isCard
        self.isSubstitution = isSubstitution
    }
}

nonisolated struct SportsTeamStat: Codable, Hashable {
    let name: String
    /// Numeric value for drawing the per-team bar; `nil` when non-numeric.
    let homeValue: Double?
    let awayValue: Double?
    let homeDisplay: String
    let awayDisplay: String
}

nonisolated struct SportsLineupPlayer: Codable, Hashable {
    let name: String
    let jersey: String?
    let position: String?
}

nonisolated struct SportsLineup: Codable, Hashable {
    let teamId: String
    let formation: String?
    let starters: [SportsLineupPlayer]
}

nonisolated struct SportsEventDetail: Codable, Hashable {
    let keyEvents: [SportsKeyEvent]
    let teamStats: [SportsTeamStat]
    let lineups: [SportsLineup]

    init(keyEvents: [SportsKeyEvent] = [], teamStats: [SportsTeamStat] = [], lineups: [SportsLineup] = []) {
        self.keyEvents = keyEvents
        self.teamStats = teamStats
        self.lineups = lineups
    }
}

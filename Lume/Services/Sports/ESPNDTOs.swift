//
//  ESPNDTOs.swift
//  Lume
//
//  Codable mirrors of ESPN's public site-API JSON (scoreboard, teams, standings,
//  summary and the F1 race-weekend shape). Every field is optional: ESPN varies
//  its payloads across sports and match states, and a missing key must degrade
//  to a nil/empty value rather than fail the decode of a whole league's refresh.
//  All types are `nonisolated` so `ESPNClient` can decode them off the main actor
//  under `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`. These types are transport
//  detail only — `ESPNClient` maps them into the provider-neutral `Sports*`
//  value types.
//

import Foundation

// MARK: - Shared primitives

/// Decodes a JSON value that ESPN sometimes renders as a string and sometimes as
/// a number (competitor scores are the usual offender), normalising both to a
/// string so mapping can parse an `Int` from it.
nonisolated struct ESPNFlexibleValue: Codable, Hashable {
    let stringValue: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            stringValue = string
        } else if let int = try? container.decode(Int.self) {
            stringValue = String(int)
        } else if let double = try? container.decode(Double.self) {
            stringValue = String(double)
        } else {
            stringValue = nil
        }
    }
}

/// A flag ESPN renders as a JSON bool in most sports and as the string
/// `"true"`/`"false"` in cricket; anything else decodes to `nil`.
nonisolated struct ESPNFlexibleBool: Codable, Hashable {
    let boolValue: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            boolValue = bool
        } else if let string = try? container.decode(String.self) {
            boolValue = Bool(string.lowercased())
        } else {
            boolValue = nil
        }
    }
}

nonisolated struct ESPNLogo: Codable, Hashable {
    let href: String?
    let rel: [String]?
}

nonisolated struct ESPNTeam: Codable, Hashable {
    let id: String?
    let displayName: String?
    let shortDisplayName: String?
    let abbreviation: String?
    let name: String?
    let location: String?
    let color: String?
    let alternateColor: String?
    /// Present on scoreboard competitors as a single crest URL.
    let logo: String?
    /// Present on the teams endpoint as a set of `rel`-tagged crests.
    let logos: [ESPNLogo]?
}

nonisolated struct ESPNAthlete: Codable, Hashable {
    let id: String?
    let displayName: String?
    let shortName: String?
    /// A tennis player's country flag — the only picture every player has.
    let flag: ESPNLogo?
}

// MARK: - Scoreboard

nonisolated struct ESPNScoreboard: Codable, Hashable {
    let leagues: [ESPNLeagueInfo]?
    let events: [ESPNEvent]?
}

nonisolated struct ESPNLeagueInfo: Codable, Hashable {
    let name: String?
    let abbreviation: String?
    let slug: String?
    let logos: [ESPNLogo]?
}

nonisolated struct ESPNEvent: Codable, Hashable {
    let id: String?
    let date: String?
    let name: String?
    let shortName: String?
    let status: ESPNStatus?
    let competitions: [ESPNCompetition]?
    /// Racing events carry their track here instead of a competition venue.
    let circuit: ESPNVenue?
    /// A tennis tournament's draws (men's singles, women's doubles…), each with
    /// its matches; tennis events carry no `competitions` of their own.
    let groupings: [ESPNGrouping]?
    let venue: ESPNVenue?
}

nonisolated struct ESPNGrouping: Codable, Hashable {
    let grouping: ESPNGroupingInfo?
    let competitions: [ESPNCompetition]?
}

nonisolated struct ESPNGroupingInfo: Codable, Hashable {
    /// "mens-singles", "womens-doubles", "mixed-doubles".
    let slug: String?
}

nonisolated struct ESPNStatus: Codable, Hashable {
    let type: ESPNStatusType?
    /// The current period: half, quarter, inning or (hockey) period number.
    let period: Int?
    /// The game clock as ESPN renders it: "68'", "45'+4'", "7:30".
    let displayClock: String?
    /// Cricket's state-of-play line: "DC won by 7 wkts (5b rem)", "RR need 40
    /// runs from 20 balls". English prose with no machine equivalent.
    let summary: String?
}

nonisolated struct ESPNStatusType: Codable, Hashable {
    let id: String?
    /// ESPN's machine name: `STATUS_FIRST_HALF`, `STATUS_HALFTIME`,
    /// `STATUS_FULL_TIME`, `STATUS_FINAL_PEN`, `STATUS_POSTPONED`… What the app
    /// localises from, since `detail`/`shortDetail` are English prose.
    let name: String?
    let state: String?
    let completed: Bool?
    let detail: String?
    let shortDetail: String?
}

nonisolated struct ESPNCompetition: Codable, Hashable {
    let id: String?
    let date: String?
    let competitors: [ESPNCompetitor]?
    let venue: ESPNVenue?
    let broadcasts: [ESPNBroadcast]?
    let status: ESPNStatus?
    /// Carries the session abbreviation (FP1/FP2/FP3/Qual/Race) for F1 weekends.
    let type: ESPNCompetitionType?
    /// A tennis match's stage: "Round 2", "Quarterfinal", "Qualifying Final".
    let round: ESPNRound?
    /// `false` when `date` is a placeholder day, not a scheduled start (tennis).
    let timeValid: Bool?
}

nonisolated struct ESPNRound: Codable, Hashable {
    let displayName: String?
}

nonisolated struct ESPNCompetitionType: Codable, Hashable {
    /// A key event's stable type id ("70" goal, "76" substitution, "94" yellow
    /// card); absent on a race session's competition type.
    let id: String?
    let abbreviation: String?
    let text: String?
}

nonisolated struct ESPNVenue: Codable, Hashable {
    let fullName: String?
    /// Tennis events name their city here ("Chengdu, China PR").
    let displayName: String?
}

nonisolated struct ESPNBroadcast: Codable, Hashable {
    let names: [String]?
}

nonisolated struct ESPNCompetitor: Codable, Hashable {
    let id: String?
    let homeAway: String?
    let score: ESPNFlexibleValue?
    let winner: ESPNFlexibleBool?
    let form: String?
    let records: [ESPNRecord]?
    let team: ESPNTeam?
    /// A tennis singles player, in place of `team`.
    let athlete: ESPNAthlete?
    /// A tennis player's games per set.
    let linescores: [ESPNLinescore]?
}

nonisolated struct ESPNLinescore: Codable, Hashable {
    let value: Double?
    let tiebreak: Int?
    /// Set once the set is over; absent on the set in play.
    let winner: Bool?
}

nonisolated struct ESPNRecord: Codable, Hashable {
    let name: String?
    let type: String?
    let summary: String?
}

// MARK: - Teams

nonisolated struct ESPNTeamsResponse: Codable, Hashable {
    let sports: [ESPNSport]?
}

nonisolated struct ESPNSport: Codable, Hashable {
    let leagues: [ESPNTeamsLeague]?
}

nonisolated struct ESPNTeamsLeague: Codable, Hashable {
    let teams: [ESPNTeamWrapper]?
}

nonisolated struct ESPNTeamWrapper: Codable, Hashable {
    let team: ESPNTeam?
}

// MARK: - Standings

nonisolated struct ESPNStandingsResponse: Codable, Hashable {
    let children: [ESPNStandingsChild]?
    /// Single-table leagues (AFL, NBL) put the entries here with no `children`.
    let standings: ESPNStandingsGroup?
}

nonisolated struct ESPNStandingsChild: Codable, Hashable {
    let name: String?
    let standings: ESPNStandingsGroup?
}

nonisolated struct ESPNStandingsGroup: Codable, Hashable {
    let entries: [ESPNStandingsEntry]?
}

nonisolated struct ESPNStandingsEntry: Codable, Hashable {
    let team: ESPNTeam?
    let athlete: ESPNAthlete?
    let stats: [ESPNStat]?
}

nonisolated struct ESPNStat: Codable, Hashable {
    let name: String?
    let abbreviation: String?
    let displayValue: String?
    let value: Double?
}

// MARK: - Rankings (tennis)

nonisolated struct ESPNRankingsResponse: Codable, Hashable {
    let rankings: [ESPNRanking]?
}

nonisolated struct ESPNRanking: Codable, Hashable {
    let ranks: [ESPNRank]?
}

nonisolated struct ESPNRank: Codable, Hashable {
    let current: Int?
    let previous: Int?
    let points: Double?
    let athlete: ESPNRankedAthlete?
}

/// The rankings feed spells the short name `shortname`, unlike the scoreboard.
nonisolated struct ESPNRankedAthlete: Codable, Hashable {
    let id: String?
    let displayName: String?
    let shortname: String?
    let flag: String?
    let flagAltText: String?
}

// MARK: - Summary (event detail)

nonisolated struct ESPNSummaryResponse: Codable, Hashable {
    let boxscore: ESPNBoxscore?
    let rosters: [ESPNRoster]?
    let keyEvents: [ESPNKeyEvent]?
}

nonisolated struct ESPNBoxscore: Codable, Hashable {
    let teams: [ESPNBoxscoreTeam]?
}

nonisolated struct ESPNBoxscoreTeam: Codable, Hashable {
    let homeAway: String?
    let team: ESPNTeam?
    let statistics: [ESPNBoxscoreStat]?
}

nonisolated struct ESPNBoxscoreStat: Codable, Hashable {
    let name: String?
    let label: String?
    let abbreviation: String?
    let displayValue: String?
    let value: Double?
}

nonisolated struct ESPNRoster: Codable, Hashable {
    let homeAway: String?
    let formation: String?
    let team: ESPNTeam?
    let roster: [ESPNRosterEntry]?
}

nonisolated struct ESPNRosterEntry: Codable, Hashable {
    let athlete: ESPNAthlete?
    let jersey: String?
    let position: ESPNPosition?
    let starter: Bool?
}

nonisolated struct ESPNPosition: Codable, Hashable {
    let abbreviation: String?
    let name: String?
}

nonisolated struct ESPNKeyEvent: Codable, Hashable {
    let type: ESPNCompetitionType?
    let clock: ESPNClock?
    let team: ESPNTeamRef?
    let scoringPlay: Bool?
    let yellowCard: Bool?
    let redCard: Bool?
    let penaltyKick: Bool?
    let ownGoal: Bool?
    let athletesInvolved: [ESPNAthlete]?
    let participants: [ESPNParticipant]?
}

nonisolated struct ESPNClock: Codable, Hashable {
    let displayValue: String?
}

nonisolated struct ESPNTeamRef: Codable, Hashable {
    let id: String?
}

nonisolated struct ESPNParticipant: Codable, Hashable {
    let athlete: ESPNAthlete?
}

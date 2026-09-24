//
//  SportsEventDetail.swift
//  Lume
//
//  The provider-neutral game-detail value types — timeline key events, team
//  stat rows and lineups — behind the game-detail sheets. Split from
//  `SportsModels.swift` to keep that file under the length cap.
//

import Foundation

// MARK: - Event detail

nonisolated struct SportsKeyEvent: Codable, Hashable {
    /// Match clock display, e.g. "45'+2" or "12:03".
    let clock: String
    /// Provider event text, e.g. "Goal", "Yellow Card" — English, the fallback
    /// when `typeId` is unknown to `localizedTitle`.
    let type: String
    /// The provider's stable event type id ("70" goal, "94" yellow card).
    let typeId: String?
    let teamId: String?
    let participants: [String]
    let isGoal: Bool
    let isCard: Bool
    let isSubstitution: Bool

    init(
        clock: String,
        type: String,
        typeId: String? = nil,
        teamId: String? = nil,
        participants: [String] = [],
        isGoal: Bool = false,
        isCard: Bool = false,
        isSubstitution: Bool = false
    ) {
        self.clock = clock
        self.type = type
        self.typeId = typeId
        self.teamId = teamId
        self.participants = participants
        self.isGoal = isGoal
        self.isCard = isCard
        self.isSubstitution = isSubstitution
    }
}

nonisolated struct SportsTeamStat: Codable, Hashable {
    /// The provider's English label ("Corner Kicks"); shown only when `key` has
    /// no localised label.
    let name: String
    /// The provider's stable stat key ("wonCorners", "possessionPct").
    let key: String?
    /// Numeric value for drawing the per-team bar; `nil` when non-numeric.
    let homeValue: Double?
    let awayValue: Double?
    let homeDisplay: String
    let awayDisplay: String

    init(name: String, key: String? = nil, homeValue: Double?, awayValue: Double?, homeDisplay: String, awayDisplay: String) {
        self.name = name
        self.key = key
        self.homeValue = homeValue
        self.awayValue = awayValue
        self.homeDisplay = homeDisplay
        self.awayDisplay = awayDisplay
    }
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

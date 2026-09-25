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
    case germany
    case ukAndIreland
    case spain
    case italy
    case france
    case netherlands
    case portugal
    case europe
    case clubCompetitions
    case international
    case womensFootball
    case americas
    case restOfWorld
    case americanFootball
    case basketball
    case iceHockey
    case baseball
    case rugby
    case australianFootball
    case cricket
    case tennis
    case lacrosse
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
    /// English prose — only ever shown when the machine fields below are missing.
    let detail: String
    let shortDetail: String
    /// The provider's machine status name (`STATUS_HALFTIME`, `STATUS_FINAL_PEN`…);
    /// what `phase` and the localised status lines derive from. `nil` on
    /// app-derived statuses (race sessions) and in snapshots written before the
    /// field existed.
    let typeName: String?
    /// The current half / quarter / period / inning number.
    let period: Int?
    /// The game clock as the provider renders it: "68'", "45'+4'", "7:30".
    let clock: String?
    /// The provider's state-of-play sentence, which cricket uses for both the
    /// live chase ("RR need 40 runs from 20 balls") and the result ("DC won by 7
    /// wkts"). English prose, shown verbatim because nothing machine-readable
    /// says the same.
    let summary: String?

    init(
        state: SportsFixtureState,
        detail: String = "",
        shortDetail: String = "",
        typeName: String? = nil,
        period: Int? = nil,
        clock: String? = nil,
        summary: String? = nil
    ) {
        self.state = state
        self.detail = detail
        self.shortDetail = shortDetail
        self.typeName = typeName
        self.period = period
        self.clock = clock
        self.summary = summary
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
    /// The provider's score when it is not a plain number — cricket's "225/6",
    /// "134 & 189/4 (25.3 ov, target 133)". Shown verbatim, never compared.
    let scoreText: String?
    let isWinner: Bool
    /// Recent-form string, e.g. "WWDWW".
    let form: String?
    /// Season record summary, e.g. "12-3-4".
    let record: String?
    /// A tennis player's games per set (`score` is then the sets won); `nil` elsewhere.
    let sets: [SportsSetScore]?

    init(
        team: SportsTeam,
        score: Int? = nil,
        scoreText: String? = nil,
        isWinner: Bool = false,
        form: String? = nil,
        record: String? = nil,
        sets: [SportsSetScore]? = nil
    ) {
        self.team = team
        self.score = score
        self.scoreText = scoreText
        self.isWinner = isWinner
        self.form = form
        self.record = record
        self.sets = sets
    }
}

/// A weekend session for a race sport (F1): FP1/FP2/FP3/Qual/Race and its time.
/// A race weekend's sessions, keyed by ESPN's competition type abbreviations.
/// Sprint weekends replace FP2/FP3 with `SS` (sprint qualifying) and `SR`
/// (the sprint itself).
nonisolated enum SportsSessionKind: String, Codable, Hashable {
    case fp1 = "FP1"
    case fp2 = "FP2"
    case fp3 = "FP3"
    case sprintQualifying = "SS"
    case sprint = "SR"
    case qualifying = "Qual"
    case race = "Race"

    var displayName: LocalizedStringResource {
        switch self {
        case .fp1: "Free Practice 1"
        case .fp2: "Free Practice 2"
        case .fp3: "Free Practice 3"
        case .sprintQualifying: "Sprint Qualifying"
        case .sprint: "Sprint"
        case .qualifying: "Qualifying"
        case .race: "Race"
        }
    }
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
    /// The provider's event title and its short form ("Italian Grand Prix" /
    /// "Italian GP", "UFC 332: Silva vs. Wang" / "UFC 332"). What a card shows
    /// when the event has no two teams to name it by; `nil` in snapshots written
    /// before the field existed.
    let name: String?
    let shortName: String?
    /// Set on a card that stands for one session of a race weekend (see
    /// `expandedBySession`); `nil` on the weekend itself and on every other
    /// fixture.
    let sessionKind: SportsSessionKind?
    /// The competition's crest as the provider served it with this fixture — the
    /// curated catalogue carries none, so this is where headers get theirs.
    let leagueLogoURL: URL?
    /// A tennis match's stage as the provider names it ("Quarterfinal", "Round 2").
    let round: String?
    /// `startDate` is only the day: a tennis match not yet on an order of play.
    let startTimeIsTentative: Bool?

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
        sessions: [SportsSession] = [],
        name: String? = nil,
        shortName: String? = nil,
        sessionKind: SportsSessionKind? = nil,
        leagueLogoURL: URL? = nil,
        round: String? = nil,
        startTimeIsTentative: Bool? = nil
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
        self.name = name
        self.shortName = shortName
        self.sessionKind = sessionKind
        self.leagueLogoURL = leagueLogoURL
        self.round = round
        self.startTimeIsTentative = startTimeIsTentative
    }
}

nonisolated extension SportsFixture {
    /// The provider's event id. A session card's `id` carries a "#Race"-style
    /// suffix so the cards of one weekend stay distinct; detail fetches need the
    /// bare id.
    var eventId: String {
        id.split(separator: "#", maxSplits: 1).first.map(String.init) ?? id
    }

    /// A race weekend as one card per session — each dated at its own start,
    /// with a status read off the clock, since the provider's status covers the
    /// whole weekend. Every other fixture passes through unchanged.
    func expandedBySession(now: Date) -> [SportsFixture] {
        guard sessions.count > 1 else { return [self] }
        return sessions.map { session in
            SportsFixture(
                id: "\(id)#\(session.kind.rawValue)",
                leagueId: leagueId,
                leagueName: leagueName,
                leagueAbbreviation: leagueAbbreviation,
                startDate: session.date,
                status: sessionStatus(session, now: now),
                venue: venue,
                broadcasters: broadcasters,
                sessions: sessions,
                name: name,
                shortName: shortName,
                sessionKind: session.kind,
                leagueLogoURL: leagueLogoURL
            )
        }
    }

    /// A finished or postponed weekend marks every session the same; otherwise
    /// a session is live from its start until a generous running time has
    /// passed, then finished.
    private func sessionStatus(_ session: SportsSession, now: Date) -> SportsFixtureStatus {
        switch status.state {
        case .final, .postponed:
            return SportsFixtureStatus(state: status.state)
        case .scheduled, .inProgress:
            let runningTime: TimeInterval = session.kind == .race ? 2.5 * 3600 : 1.25 * 3600
            if now < session.date { return SportsFixtureStatus(state: .scheduled) }
            if now < session.date.addingTimeInterval(runningTime) { return SportsFixtureStatus(state: .inProgress) }
            return SportsFixtureStatus(state: .final)
        }
    }

    /// Whether the event is named by two teams (a match) rather than by itself
    /// (a race weekend, a fight night).
    var hasTeams: Bool {
        home?.team != nil || away?.team != nil
    }

    /// The title for a competitor-less event: the provider's event name, else the
    /// venue, else the competition.
    var eventTitle: String {
        name ?? venue ?? leagueName
    }

    /// The compact title for narrow cards ("Italian GP", "UFC 332").
    var eventShortTitle: String {
        shortName ?? eventTitle
    }

    /// The venue line under an event title, only when it adds something the
    /// title didn't already say.
    var eventSubtitle: String? {
        guard let venue, name != nil else { return nil }
        return venue
    }

    /// The weekend's main event — the race — when the provider listed sessions.
    var raceSession: SportsSession? {
        sessions.first { $0.kind == .race } ?? sessions.last
    }

    /// The sport of the fixture's competition, read off the "espn:{sport}/{slug}"
    /// league id — what period and status labels are phrased for.
    var sport: String {
        let afterPrefix = leagueId.split(separator: ":", maxSplits: 1).last ?? Substring(leagueId)
        return String(afterPrefix.split(separator: "/", maxSplits: 1).first ?? afterPrefix)
    }

    /// The moment a card headlines: a session card's own start; the race for an
    /// unexpanded weekend (`startDate` is the first practice, which is not what
    /// anyone tunes in for); else the fixture's own start.
    var headlineDate: Date {
        if sessionKind != nil { return startDate }
        return raceSession?.date ?? startDate
    }

    /// Whether the headline falls on a different day than the fixture's start,
    /// so a card must name the day next to the time.
    var headlineIsOnAnotherDay: Bool {
        !Calendar.current.isDate(headlineDate, inSameDayAs: startDate)
    }

    /// Whether the headline falls on today's calendar day. A card names the date
    /// otherwise, so a Saturday kickoff in Monday's rail is not read as today's.
    var headlineIsToday: Bool {
        Calendar.current.isDateInToday(headlineDate)
    }
}

// MARK: - Standings

nonisolated enum SportsStandingKind: String, Codable, Hashable {
    case team
    case driver
    case constructor
    /// A tennis tour's world ranking: a player per row, ranked on points.
    case player
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
    /// The provider's table this row belongs to when a league has several —
    /// "American Football Conference", "Driver Standings" — so the rows render
    /// as separate tables instead of one list whose ranks restart. `nil` for a
    /// single-table league and in snapshots written before the field existed.
    let group: String?

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
        extra: [String: String] = [:],
        group: String? = nil
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
        self.group = group
    }
}

/// One table of a league's standings: a conference, a division, F1's drivers
/// or constructors — or the whole league when it has just one.
nonisolated struct SportsStandingGroup: Identifiable, Hashable {
    let id: String
    let name: String?
    let kind: SportsStandingKind
    let rows: [SportsStandingRow]
}

nonisolated extension SportsStandingRow {
    /// Splits a flat standings list into its tables, in first-appearance order.
    /// Rows split on the provider's group name and, for snapshots written before
    /// groups were recorded, on kind — so an old F1 cache still separates
    /// drivers from constructors.
    static func grouped(_ rows: [SportsStandingRow]) -> [SportsStandingGroup] {
        var order: [String] = []
        var buckets: [String: (name: String?, kind: SportsStandingKind, rows: [SportsStandingRow])] = [:]
        for row in rows {
            let key = "\(row.group ?? "")|\(row.kind.rawValue)"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = (row.group, row.kind, [])
            }
            buckets[key]?.rows.append(row)
        }
        return order.compactMap { key in
            buckets[key].map { SportsStandingGroup(id: key, name: $0.name, kind: $0.kind, rows: $0.rows) }
        }
    }
}

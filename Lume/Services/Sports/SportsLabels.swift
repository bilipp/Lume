//
//  SportsLabels.swift
//  Lume
//
//  Localised labels for provider data. ESPN's `detail`/`shortDetail`, key-event
//  texts and stat labels are English prose in every request language except
//  Spanish and Portuguese (and only half-translated there), but each arrives
//  beside a stable machine field — status name, period, clock, event type id,
//  stat key. Everything here derives a label from those fields and falls back to
//  the provider's English string, so an unknown value looks exactly as it did
//  before the field was decoded.
//

import Foundation

// MARK: - Status phase

/// Where a game is, read off the provider's machine status name, independent of
/// sport and language.
nonisolated enum SportsStatusPhase: Hashable {
    case scheduled
    case inProgress
    case halftime
    case endOfPeriod
    case overtime
    case extraTime
    case penaltyShootout
    case delayed
    case suspended
    case final
    case finalAfterExtraTime
    case finalAfterPenalties
    case postponed
    case canceled
    case abandoned

    /// Reads the status name (`STATUS_HALFTIME`, `STATUS_FINAL_PEN`…); a status
    /// recorded without one falls back to the English detail's stoppage words,
    /// then to its coarse state, which is all older snapshots carry.
    init(typeName: String?, state: SportsFixtureState, detail: String) {
        let name = (typeName ?? "").uppercased()
        if let match = Self.namePatterns.first(where: { name.contains($0.needle) }) {
            self = match.phase
            return
        }
        let lowerDetail = detail.lowercased()
        if let match = Self.detailPatterns.first(where: { lowerDetail.contains($0.needle) }) {
            self = match.phase
            return
        }
        self = Self.phase(for: state)
    }

    /// Substrings of ESPN's status names, most specific first: `FINAL_PEN` must
    /// win over `FINAL`, `SUSPENDED` over the `PEN` inside it, `HALF_TIME` over
    /// `EXTRA`, and the bare `HALF` of `FIRST_HALF` comes last.
    private static let namePatterns: [(needle: String, phase: SportsStatusPhase)] = [
        ("POSTPONE", .postponed), ("CANCEL", .canceled), ("ABANDON", .abandoned),
        ("SUSPEND", .suspended), ("DELAY", .delayed),
        ("HALFTIME", .halftime), ("HALF_TIME", .halftime),
        ("FINAL_AET", .finalAfterExtraTime), ("FINAL_PEN", .finalAfterPenalties),
        ("FINAL", .final), ("FULL_TIME", .final),
        ("SHOOTOUT", .penaltyShootout), ("PEN", .penaltyShootout),
        ("EXTRA", .extraTime), ("OVERTIME", .overtime),
        ("END_PERIOD", .endOfPeriod), ("END_OF_PERIOD", .endOfPeriod),
        ("SCHEDULED", .scheduled), ("HALF", .inProgress), ("IN_PROGRESS", .inProgress)
    ]

    private static let detailPatterns: [(needle: String, phase: SportsStatusPhase)] = [
        ("postpone", .postponed), ("cancel", .canceled), ("abandon", .abandoned)
    ]

    private static func phase(for state: SportsFixtureState) -> SportsStatusPhase {
        switch state {
        case .scheduled: .scheduled
        case .inProgress: .inProgress
        case .final: .final
        case .postponed: .postponed
        }
    }

    /// A game that will not be played (today): what `SportsFixtureState.postponed`
    /// stands for.
    var isStoppage: Bool {
        switch self {
        case .postponed, .canceled, .abandoned: true
        default: false
        }
    }
}

// MARK: - Period families

/// How a sport divides its playing time, which decides how a live status line is
/// phrased: soccer shows its running clock alone, the quarter sports pair the
/// clock with "3rd Quarter", baseball names the inning.
nonisolated enum SportsPeriodFamily: Hashable {
    /// Soccer, rugby, Australian football: the clock ("68'") says it all.
    case clockOnly
    case quarters
    case halves
    /// Ice hockey's three periods.
    case periods
    case innings
    /// Race weekends, tennis, golf, fights: no period structure to label.
    case none

    /// Sport slug plus league slug, since college basketball plays halves where
    /// the professional leagues play quarters.
    init(sport: String, leagueSlug: String) {
        switch sport {
        case "football":
            self = .quarters
        case "basketball":
            self = leagueSlug.contains("college") ? .halves : .quarters
        case "hockey":
            self = .periods
        case "baseball":
            self = .innings
        case "soccer", "rugby", "rugby-league", "australian-football", "lacrosse", "volleyball", "cricket", "field-hockey":
            self = .clockOnly
        default:
            self = .none
        }
    }

    /// Periods in a regulation game; `nil` where the notion does not apply.
    var regulationPeriods: Int? {
        switch self {
        case .quarters: 4
        case .halves: 2
        case .periods: 3
        case .innings: 9
        case .clockOnly, .none: nil
        }
    }
}

nonisolated extension SportsFixture {
    var periodFamily: SportsPeriodFamily {
        SportsPeriodFamily(sport: sport, leagueSlug: leagueSlug)
    }

    /// The competition's slug from the "espn:{sport}/{slug}" league id.
    var leagueSlug: String {
        String(leagueId.split(separator: "/", maxSplits: 1).last ?? "")
    }
}

// MARK: - Period labels

nonisolated enum SportsPeriodLabel {
    /// "3rd Quarter", "2nd Half", "1st Period", "Overtime", "Overtime 2",
    /// "Shootout" — `nil` where the family has no periods to name.
    static func label(family: SportsPeriodFamily, period: Int?) -> String? {
        guard let period, period > 0, let regulation = family.regulationPeriods else { return nil }
        if period > regulation {
            let extra = period - regulation
            if family == .periods, extra >= 2 { return String(localized: "Shootout") }
            return extra == 1 ? String(localized: "Overtime") : String(localized: "Overtime \(extra)")
        }
        let ordinal = ordinal(period)
        switch family {
        case .quarters: return String(localized: "\(ordinal) Quarter")
        case .halves: return String(localized: "\(ordinal) Half")
        case .periods: return String(localized: "\(ordinal) Period")
        case .innings: return String(localized: "\(ordinal) Inning")
        case .clockOnly, .none: return nil
        }
    }

    /// Baseball names the half-inning too, but only in the English detail
    /// ("Bottom 8th"), so that prefix is read off it; without one the inning
    /// stands alone.
    static func inningLabel(period: Int?, detail: String) -> String? {
        guard let period, period > 0 else { return nil }
        let ordinal = ordinal(period)
        let lower = detail.lowercased()
        if lower.hasPrefix("top") { return String(localized: "Top of the \(ordinal)") }
        if lower.hasPrefix("bot") { return String(localized: "Bottom of the \(ordinal)") }
        if lower.hasPrefix("mid") { return String(localized: "Middle of the \(ordinal)") }
        if lower.hasPrefix("end") { return String(localized: "End of the \(ordinal)") }
        return String(localized: "\(ordinal) Inning")
    }

    /// "3rd" / "3." / "3e" / "第3" — the current locale's ordinal.
    static func ordinal(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}

// MARK: - Status lines

nonisolated extension SportsFixtureStatus {
    var phase: SportsStatusPhase {
        SportsStatusPhase(typeName: typeName, state: state, detail: detail)
    }

    /// The line under a LIVE badge: the soccer clock ("68'"), "Half-time", or
    /// the clock beside the period for period sports ("7:30 · 3rd Quarter").
    /// `nil` when the badge already says everything; the provider's English
    /// short detail when the machine fields were not recorded.
    func localizedLiveDetail(family: SportsPeriodFamily) -> String? {
        let phase = phase
        if let label = Self.phaseLabels[phase] {
            let text = String(localized: label)
            return Self.clockedPhases.contains(phase) ? Self.join(runningClock, text) : text
        }
        switch phase {
        case .inProgress:
            return progressLine(family: family)
        case .endOfPeriod:
            guard let label = SportsPeriodLabel.label(family: family, period: period) else { return fallbackDetail }
            return String(localized: "End of \(label)")
        default:
            return nil
        }
    }

    /// Live phases that are a fixed word rather than a clock reading.
    private static let phaseLabels: [SportsStatusPhase: LocalizedStringResource] = [
        .halftime: "Half-time",
        .penaltyShootout: "Penalty shootout",
        .delayed: "Delayed",
        .suspended: "Suspended",
        .overtime: "Overtime",
        .extraTime: "Extra time"
    ]

    /// Of those, the ones whose clock keeps running and is worth showing.
    private static let clockedPhases: Set<SportsStatusPhase> = [.overtime, .extraTime]

    private func progressLine(family: SportsPeriodFamily) -> String? {
        switch family {
        case .clockOnly:
            runningClock ?? fallbackDetail
        case .quarters, .halves, .periods:
            Self.join(runningClock, SportsPeriodLabel.label(family: family, period: period)) ?? fallbackDetail
        case .innings:
            SportsPeriodLabel.inningLabel(period: period, detail: detail) ?? fallbackDetail
        case .none:
            fallbackDetail
        }
    }

    /// The word on a postponed card.
    var localizedStoppage: String {
        switch phase {
        case .canceled: String(localized: "Canceled")
        case .abandoned: String(localized: "Abandoned")
        case .suspended: String(localized: "Suspended")
        default: String(localized: "Postponed")
        }
    }

    /// How a finished game went past regulation — "After extra time", "After
    /// penalties", "After overtime" — or `nil` when it did not.
    func localizedEndingQualifier(family: SportsPeriodFamily) -> String? {
        switch phase {
        case .finalAfterExtraTime:
            return String(localized: "After extra time")
        case .finalAfterPenalties:
            return String(localized: "After penalties")
        case .final:
            guard let period, let regulation = family.regulationPeriods, period > regulation else { return nil }
            switch family {
            case .periods where period >= regulation + 2:
                return String(localized: "After shootout")
            case .innings:
                return String(localized: "After extra innings")
            default:
                return String(localized: "After overtime")
            }
        default:
            return nil
        }
    }

    /// The clock when it is running; a stopped "0:00" / "0'" says nothing.
    private var runningClock: String? {
        guard let clock = clock?.trimmingCharacters(in: .whitespaces), !clock.isEmpty else { return nil }
        if clock == "0:00" || clock == "0'" || clock == "0.0" { return nil }
        return clock
    }

    private var fallbackDetail: String? {
        shortDetail.isEmpty ? nil : shortDetail
    }

    private static func join(_ clock: String?, _ label: String?) -> String? {
        switch (clock, label) {
        case let (clock?, label?): "\(clock) · \(label)"
        case let (clock?, nil): clock
        case let (nil, label?): label
        case (nil, nil): nil
        }
    }
}

// MARK: - Key events

nonisolated extension SportsKeyEvent {
    /// The timeline row's title, from the provider's stable type id, else from
    /// its English text, else that text verbatim.
    var localizedTitle: String {
        if let typeId, let title = Self.title(forTypeId: typeId) { return title }
        return Self.title(forText: type) ?? type
    }

    /// Whether a card event is the yellow one; the red is the other card.
    var isYellowCard: Bool {
        typeId == "94" || type.range(of: "yellow", options: .caseInsensitive) != nil
    }

    private static func title(forTypeId id: String) -> String? {
        titlesByTypeId[id].map { String(localized: $0) }
    }

    private static func title(forText text: String) -> String? {
        titlesByText[text.lowercased()].map { String(localized: $0) }
    }

    /// ESPN's soccer key-event type ids.
    private static let titlesByTypeId: [String: LocalizedStringResource] = [
        "70": "Goal",
        "137": "Goal (header)",
        "138": "Goal (free kick)",
        "173": "Goal (volley)",
        "97": "Own goal",
        "98": "Penalty scored",
        "114": "Penalty saved",
        "93": "Red card",
        "94": "Yellow card",
        "76": "Substitution",
        "80": "Kick-off",
        "81": "Half-time",
        "82": "Second half",
        "83": "End of regular time"
    ]

    /// The same events by their English text, for ids this table does not know.
    private static let titlesByText: [String: LocalizedStringResource] = [
        "goal": "Goal",
        "goal - header": "Goal (header)",
        "goal - free-kick": "Goal (free kick)",
        "goal - volley": "Goal (volley)",
        "own goal": "Own goal",
        "penalty - scored": "Penalty scored",
        "penalty - saved": "Penalty saved",
        "penalty - missed": "Penalty missed",
        "red card": "Red card",
        "yellow card": "Yellow card",
        "substitution": "Substitution",
        "kickoff": "Kick-off",
        "halftime": "Half-time",
        "start 2nd half": "Second half",
        "end regular time": "End of regular time"
    ]
}

// MARK: - Team stats

nonisolated extension SportsTeamStat {
    /// The stat row's caption, from the provider's stable key; its English label
    /// for a key without a localised one.
    var localizedName: String {
        guard let key, let label = Self.label(forKey: key) else { return name }
        return label
    }

    private static func label(forKey key: String) -> String? {
        labelsByKey[key].map { String(localized: $0) }
    }

    /// ESPN's boxscore stat keys for soccer, American football, basketball and
    /// ice hockey; a key shared by two sports ("interceptions", "turnovers")
    /// gets the label that reads right in both.
    private static let labelsByKey: [String: LocalizedStringResource] = [
        "foulsCommitted": "Fouls",
        "fouls": "Fouls",
        "yellowCards": "Yellow cards",
        "redCards": "Red cards",
        "offsides": "Offsides",
        "wonCorners": "Corner kicks",
        "saves": "Saves",
        "possessionPct": "Possession",
        "totalShots": "Shots",
        "shotsTotal": "Shots",
        "shotsOnTarget": "Shots on target",
        "shotPct": "Shot accuracy",
        "penaltyKickGoals": "Penalty goals",
        "penaltyKickShots": "Penalties taken",
        "accuratePasses": "Accurate passes",
        "totalPasses": "Passes",
        "passPct": "Pass accuracy",
        "accurateCrosses": "Accurate crosses",
        "totalCrosses": "Crosses",
        "crossPct": "Cross accuracy",
        "totalLongBalls": "Long balls",
        "accurateLongBalls": "Accurate long balls",
        "longballPct": "Long ball accuracy",
        "blockedShots": "Blocked shots",
        "effectiveTackles": "Successful tackles",
        "totalTackles": "Tackles",
        "tacklePct": "Tackle success",
        "interceptions": "Interceptions",
        "effectiveClearance": "Effective clearances",
        "totalClearance": "Clearances",
        "firstDowns": "First downs",
        "firstDownsPassing": "Passing first downs",
        "firstDownsRushing": "Rushing first downs",
        "firstDownsPenalty": "First downs by penalty",
        "thirdDownEff": "Third-down efficiency",
        "fourthDownEff": "Fourth-down efficiency",
        "totalOffensivePlays": "Total plays",
        "totalYards": "Total yards",
        "yardsPerPlay": "Yards per play",
        "totalDrives": "Drives",
        "netPassingYards": "Passing yards",
        "completionAttempts": "Completions / attempts",
        "yardsPerPass": "Yards per pass",
        "sacksYardsLost": "Sacks / yards lost",
        "rushingYards": "Rushing yards",
        "rushingAttempts": "Rushing attempts",
        "yardsPerRushAttempt": "Yards per rush",
        "redZoneAttempts": "Red zone (made / attempts)",
        "totalPenaltiesYards": "Penalties / yards",
        "turnovers": "Turnovers",
        "fumblesLost": "Fumbles lost",
        "defensiveTouchdowns": "Defensive and special-teams touchdowns",
        "possessionTime": "Time of possession",
        "fieldGoalsMade-fieldGoalsAttempted": "Field goals",
        "fieldGoalPct": "Field goal %",
        "threePointFieldGoalsMade-threePointFieldGoalsAttempted": "Three-pointers",
        "threePointFieldGoalPct": "Three-point %",
        "freeThrowsMade-freeThrowsAttempted": "Free throws",
        "freeThrowPct": "Free throw %",
        "totalRebounds": "Rebounds",
        "offensiveRebounds": "Offensive rebounds",
        "defensiveRebounds": "Defensive rebounds",
        "assists": "Assists",
        "steals": "Steals",
        "blocks": "Blocks",
        "teamTurnovers": "Team turnovers",
        "totalTurnovers": "Total turnovers",
        "technicalFouls": "Technical fouls",
        "totalTechnicalFouls": "Total technical fouls",
        "flagrantFouls": "Flagrant fouls",
        "turnoverPoints": "Points off turnovers",
        "fastBreakPoints": "Fast-break points",
        "pointsInPaint": "Points in the paint",
        "largestLead": "Largest lead",
        "leadChanges": "Lead changes",
        "leadPercentage": "Time in the lead",
        "hits": "Hits",
        "takeaways": "Takeaways",
        "giveaways": "Giveaways",
        "powerPlayGoals": "Power-play goals",
        "powerPlayOpportunities": "Power-play opportunities",
        "powerPlayPct": "Power-play %",
        "shortHandedGoals": "Short-handed goals",
        "shootoutGoals": "Shootout goals",
        "faceoffsWon": "Faceoffs won",
        "faceoffPercent": "Faceoff win %",
        "penalties": "Penalties",
        "penaltyMinutes": "Penalty minutes"
    ]
}

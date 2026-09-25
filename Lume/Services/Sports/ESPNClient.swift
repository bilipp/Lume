//
//  ESPNClient.swift
//  Lume
//
//  The v1 `SportsDataProvider`, backed by ESPN's public, keyless site API. It is
//  a `nonisolated struct` with an injectable `URLSession` (the TMDB/MDBList
//  read-client house pattern) so refreshes run off the main actor — the hub must
//  never await ESPN on `MainActor`.
//
//  Resilience is the contract: a non-2xx response or a decode failure degrades to
//  an empty result ([] / nil) plus a `Logger.network` warning, never a thrown
//  error, so one bad league can't abort a multi-league refresh. Scoreboards are
//  fetched with `?dates=YYYYMM` (a whole month) or `?dates=YYYYMMDD` (one day);
//  ESPN date *ranges* return zero events, so they are never used.
//

import Foundation
import OSLog

nonisolated struct ESPNClient: SportsDataProvider {
    static let shared = ESPNClient()

    private let session: URLSession
    private let requestTimeout: TimeInterval

    /// Site API for scoreboards, teams and summaries.
    private static let siteAPIBase = URL(string: "https://site.api.espn.com/apis/site/v2/sports")!
    /// Web API for standings (a different host and path prefix).
    private static let webAPIBase = URL(string: "https://site.web.api.espn.com/apis/v2/sports")!

    init(session: URLSession = .shared, requestTimeout: TimeInterval = 15) {
        self.session = session
        self.requestTimeout = requestTimeout
    }

    /// ESPN needs no key, so it is always usable.
    var isConfigured: Bool {
        true
    }

    // MARK: - SportsDataProvider

    func fixtures(league: SportsLeague, month: DateComponents) async throws -> [SportsFixture] {
        guard let year = month.year, let monthValue = month.month else { return [] }
        let dates = String(format: "%04d%02d", year, monthValue)
        return await scoreboardFixtures(league: league, dates: dates)
    }

    func fixtures(league: SportsLeague, day: Date) async throws -> [SportsFixture] {
        let dates = Self.dayFormatter.string(from: day)
        return await scoreboardFixtures(league: league, dates: dates)
    }

    func teams(league: SportsLeague) async throws -> [SportsTeam] {
        if league.isTennis {
            return await rankings(league: league).map(\.team)
        }
        let url = Self.siteAPIBase
            .appending(path: "\(league.sport)/\(league.slug)/teams")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "1000")])
        guard let response: ESPNTeamsResponse = await fetch(url) else { return [] }
        let wrappers = response.sports?.first?.leagues?.first?.teams ?? []
        return wrappers.compactMap { Self.mapTeam($0.team, leagueId: league.id) }
    }

    func standings(league: SportsLeague) async throws -> [SportsStandingRow] {
        if league.isTennis {
            return await rankings(league: league).map(\.row)
        }
        let url = Self.webAPIBase
            .appending(path: "\(league.sport)/\(league.slug)/standings")
        guard let response: ESPNStandingsResponse = await fetch(url) else { return [] }
        return Self.mapStandings(response)
    }

    func eventDetail(league: SportsLeague, eventId: String) async throws -> SportsEventDetail? {
        // A tennis summary is an HTTP 400 for any id: the match has no feed.
        guard !league.isTennis else { return nil }
        let url = Self.siteAPIBase
            .appending(path: "\(league.sport)/\(league.slug)/summary")
            .appending(queryItems: [URLQueryItem(name: "event", value: eventId)])
        guard let response: ESPNSummaryResponse = await fetch(url) else { return nil }
        return Self.mapEventDetail(response)
    }

    // MARK: - Scoreboard fetch + map

    private func scoreboardFixtures(league: SportsLeague, dates: String) async -> [SportsFixture] {
        let url = Self.siteAPIBase
            .appending(path: "\(league.sport)/\(league.slug)/scoreboard")
            .appending(queryItems: [URLQueryItem(name: "dates", value: dates)])
        guard let response: ESPNScoreboard = await fetch(url) else { return [] }
        return Self.mapScoreboard(response, league: league)
    }

    /// A tennis tour has no teams and no table: its players come from the world
    /// ranking, which doubles as the standings.
    private func rankings(league: SportsLeague) async -> [(team: SportsTeam, row: SportsStandingRow)] {
        let url = Self.siteAPIBase.appending(path: "\(league.sport)/\(league.slug)/rankings")
        guard let response: ESPNRankingsResponse = await fetch(url) else { return [] }
        return Self.mapRankings(response, leagueId: league.id)
    }

    // MARK: - Networking

    /// Fetches and decodes `T`, returning `nil` (and logging) on any failure so
    /// callers can degrade to an empty result. Retries once on a transient error.
    private func fetch<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        for attempt in 0 ..< 2 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    Logger.network.warning("ESPN: non-HTTP response for \(url.absoluteString, privacy: .public)")
                    return nil
                }
                guard (200 ... 299).contains(http.statusCode) else {
                    let code = http.statusCode
                    if (500 ... 599).contains(code), attempt == 0 { continue }
                    Logger.network.warning("ESPN: HTTP \(code, privacy: .public) for \(url.absoluteString, privacy: .public)")
                    return nil
                }
                do {
                    return try JSONDecoder().decode(T.self, from: data)
                } catch {
                    let message = error.localizedDescription
                    Logger.network.warning("ESPN: decode failed for \(url.absoluteString, privacy: .public): \(message, privacy: .public)")
                    return nil
                }
            } catch {
                if attempt == 0 { continue }
                let message = error.localizedDescription
                Logger.network.warning("ESPN: request failed for \(url.absoluteString, privacy: .public): \(message, privacy: .public)")
                return nil
            }
        }
        return nil
    }

    // MARK: - Formatters

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    /// ESPN emits ISO-8601 instants that are usually `…:ssZ` but sometimes drop
    /// the seconds (`…:mmZ`). Both are UTC.
    static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = isoWithSeconds.date(from: string) { return date }
        if let date = isoFractional.date(from: string) { return date }
        return isoNoSeconds.date(from: string)
    }

    private static let isoWithSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoNoSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
        return formatter
    }()
}

// MARK: - Mapping

nonisolated extension ESPNClient {
    /// The catalogue's curated name and abbreviation label every fixture; the
    /// response's own ("German Bundesliga", "Rugby League" for the NRL,
    /// "NASCAR-PREMIER") only fill a blank.
    static func mapScoreboard(_ scoreboard: ESPNScoreboard, league: SportsLeague) -> [SportsFixture] {
        let info = scoreboard.leagues?.first
        let context = ScoreboardContext(
            league: league,
            leagueName: league.name.isEmpty ? (info?.name ?? "") : league.name,
            leagueAbbreviation: league.abbreviation.isEmpty ? (info?.abbreviation ?? "") : league.abbreviation,
            leagueLogoURL: logo(info?.logos, dark: false),
            isRacing: league.sport == "racing"
        )
        if league.isTennis {
            return (scoreboard.events ?? []).flatMap { mapTennisEvent($0, context: context) }
        }
        return (scoreboard.events ?? []).compactMap { mapEvent($0, context: context) }
    }

    /// What every event of one scoreboard response shares: the competition's
    /// labels and crest, and whether its events are race weekends.
    struct ScoreboardContext {
        let league: SportsLeague
        let leagueName: String
        let leagueAbbreviation: String
        let leagueLogoURL: URL?
        let isRacing: Bool
    }

    private static func mapEvent(_ event: ESPNEvent, context: ScoreboardContext) -> SportsFixture? {
        let league = context.league
        let isRacing = context.isRacing
        guard let id = event.id else { return nil }
        let competition = event.competitions?.first
        let startDate = parseDate(event.date) ?? competition.flatMap { parseDate($0.date) } ?? Date.distantPast
        let status = mapStatus(event.status)

        var home: SportsCompetitor?
        var away: SportsCompetitor?
        for competitor in competition?.competitors ?? [] {
            guard let mapped = mapCompetitor(competitor, leagueId: league.id) else { continue }
            if competitor.homeAway == "away" {
                away = mapped
            } else {
                home = mapped
            }
        }

        let broadcasters = (competition?.broadcasts ?? [])
            .flatMap { $0.names ?? [] }
            .filter { !$0.isEmpty }

        var sessions: [SportsSession] = []
        if isRacing {
            sessions = (event.competitions ?? []).compactMap { comp in
                guard let raw = comp.type?.abbreviation,
                      let kind = SportsSessionKind(rawValue: raw),
                      let date = parseDate(comp.date)
                else { return nil }
                return SportsSession(kind: kind, date: date)
            }
        }

        return SportsFixture(
            id: id,
            leagueId: league.id,
            leagueName: context.leagueName,
            leagueAbbreviation: context.leagueAbbreviation,
            startDate: startDate,
            status: status,
            home: home,
            away: away,
            venue: competition?.venue?.fullName ?? event.circuit?.fullName,
            broadcasters: broadcasters,
            sessions: sessions,
            name: nonEmpty(event.name),
            shortName: nonEmpty(event.shortName),
            leagueLogoURL: context.leagueLogoURL
        )
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }

    /// The coarse state comes from ESPN's `state` ("pre"/"in"/"post"), except
    /// that a stoppage named by the status (`STATUS_POSTPONED`, `STATUS_CANCELED`,
    /// `STATUS_ABANDONED` — or, lacking a name, said by the English detail) is
    /// `.postponed` whatever the state says. The machine fields ride along for
    /// `SportsLabels` to phrase in the user's language.
    static func mapStatus(_ status: ESPNStatus?) -> SportsFixtureStatus {
        let type = status?.type
        let detail = type?.detail ?? ""
        let shortDetail = type?.shortDetail ?? ""
        let coarseState: SportsFixtureState = switch type?.state {
        case "in":
            .inProgress
        case "post":
            // Cricket results carry no `completed` flag at all; only an explicit
            // `false` marks a game that ended without being played out.
            (type?.completed == false) ? .postponed : .final
        default:
            .scheduled
        }
        let phase = SportsStatusPhase(typeName: type?.name, state: coarseState, detail: detail)
        return SportsFixtureStatus(
            state: phase.isStoppage ? .postponed : coarseState,
            detail: detail,
            shortDetail: shortDetail,
            typeName: type?.name,
            period: status?.period,
            clock: nonEmpty(status?.displayClock),
            summary: nonEmpty(status?.summary)
        )
    }

    private static func mapCompetitor(_ competitor: ESPNCompetitor, leagueId: String) -> SportsCompetitor? {
        guard let team = mapTeam(competitor.team, leagueId: leagueId) else { return nil }
        let rawScore = competitor.score?.stringValue.flatMap(nonEmpty)
        let score = rawScore.flatMap { Int($0) }
        let record = competitor.records?.first(where: { $0.type == "total" })?.summary
            ?? competitor.records?.first?.summary
        return SportsCompetitor(
            team: team,
            score: score,
            scoreText: score == nil ? rawScore : nil,
            isWinner: competitor.winner?.boolValue ?? false,
            form: competitor.form,
            record: record
        )
    }

    static func mapTeam(_ team: ESPNTeam?, leagueId: String) -> SportsTeam? {
        guard let team, let teamId = team.id else { return nil }
        let name = team.displayName ?? team.name ?? team.shortDisplayName ?? teamId
        let logoURL = team.logo.flatMap(URL.init(string:)) ?? logo(team.logos, dark: false)
        let darkLogoURL = logo(team.logos, dark: true)
        return SportsTeam(
            leagueId: leagueId,
            teamId: teamId,
            name: name,
            shortName: team.shortDisplayName ?? name,
            abbreviation: team.abbreviation ?? "",
            logoURL: logoURL,
            darkLogoURL: darkLogoURL,
            colorHex: normalizeHex(team.color),
            alternateColorHex: normalizeHex(team.alternateColor)
        )
    }

    /// Picks the `full/default` crest, or `full/dark` when `dark` is requested.
    private static func logo(_ logos: [ESPNLogo]?, dark: Bool) -> URL? {
        guard let logos else { return nil }
        let wanted = dark ? "dark" : "default"
        let match = logos.first { logo in
            let rel = logo.rel ?? []
            return rel.contains("full") && rel.contains(wanted)
        }
        let chosen = match ?? (dark ? nil : logos.first)
        return chosen?.href.flatMap(URL.init(string:))
    }

    /// ESPN colours arrive as bare hex without a leading `#`; keep them that way,
    /// dropping an empty or placeholder value.
    private static func normalizeHex(_ hex: String?) -> String? {
        guard let hex else { return nil }
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    }

    // MARK: Standings

    /// Walks every group (conferences, F1's driver/constructor tables) plus a
    /// single-table league's root entries (AFL, NBL). A group that names no kind
    /// is read from its rows: athlete entries are drivers (NASCAR, IndyCar).
    static func mapStandings(_ response: ESPNStandingsResponse) -> [SportsStandingRow] {
        var groups: [(name: String?, entries: [ESPNStandingsEntry])] = (response.children ?? []).map {
            ($0.name, $0.standings?.entries ?? [])
        }
        if let rootEntries = response.standings?.entries, !rootEntries.isEmpty {
            groups.append((nil, rootEntries))
        }

        var rows: [SportsStandingRow] = []
        for group in groups {
            let kind = standingKind(childName: group.name)
            let groupName = groups.count > 1 ? group.name : nil
            for (index, entry) in group.entries.enumerated() {
                let resolvedKind = kind == .team && entry.team == nil && entry.athlete != nil ? .driver : kind
                if let row = mapStandingEntry(entry, kind: resolvedKind, fallbackRank: index + 1, group: groupName) {
                    rows.append(row)
                }
            }
        }
        return rows
    }

    private static func standingKind(childName: String?) -> SportsStandingKind {
        guard let name = childName?.lowercased() else { return .team }
        if name.contains("constructor") { return .constructor }
        if name.contains("driver") { return .driver }
        return .team
    }

    /// Indexes an entry's stats by name and abbreviation and resolves the few
    /// numeric fields the standings rows need.
    private struct StandingStatLookup {
        private let byName: [String: ESPNStat]
        private let byAbbreviation: [String: ESPNStat]
        let extra: [String: String]

        init(entry: ESPNStandingsEntry) {
            var byName: [String: ESPNStat] = [:]
            var byAbbreviation: [String: ESPNStat] = [:]
            var extra: [String: String] = [:]
            for stat in entry.stats ?? [] {
                if let name = stat.name { byName[name] = stat }
                if let abbreviation = stat.abbreviation { byAbbreviation[abbreviation] = stat }
                if let key = stat.name ?? stat.abbreviation, let display = stat.displayValue {
                    extra[key] = display
                }
            }
            self.byName = byName
            self.byAbbreviation = byAbbreviation
            self.extra = extra
        }

        func intStat(_ name: String) -> Int? {
            guard let stat = byName[name] else { return nil }
            if let value = stat.value { return Int(value) }
            return stat.displayValue.flatMap { Int($0) }
        }

        /// The first of several provider spellings for one figure — rugby and
        /// the NRL say `gamesWon`/`gamesLost`/`gamesDrawn`/`pointsDifference`,
        /// cricket `matchesPlayed`/`matchesWon`/`matchesLost`/`matchPoints`,
        /// where every other sport says `wins`/`losses`/`ties`/`pointDifferential`.
        func intStat(anyOf names: [String]) -> Int? {
            for name in names {
                if let value = intStat(name) { return value }
            }
            return nil
        }

        func rankStat() -> Int? {
            if let rank = intStat("rank") { return rank }
            if let stat = byAbbreviation["RK"], let value = stat.value ?? stat.displayValue.flatMap({ Double($0) }) {
                return Int(value)
            }
            return nil
        }

        func pointsStat() -> Int? {
            if let points = intStat(anyOf: ["points", "championshipPts", "matchPoints"]) { return points }
            if let stat = byAbbreviation["PTS"], let value = stat.value ?? stat.displayValue.flatMap({ Double($0) }) {
                return Int(value)
            }
            return nil
        }
    }

    private static func mapStandingEntry(
        _ entry: ESPNStandingsEntry,
        kind: SportsStandingKind,
        fallbackRank: Int,
        group: String?
    ) -> SportsStandingRow? {
        let stats = StandingStatLookup(entry: entry)

        switch kind {
        case .team:
            guard let team = entry.team, let teamId = team.id else { return nil }
            return SportsStandingRow(
                id: teamId,
                kind: .team,
                teamId: teamId,
                name: team.displayName ?? team.shortDisplayName ?? teamId,
                rank: stats.rankStat() ?? fallbackRank,
                played: stats.intStat(anyOf: ["gamesPlayed", "matchesPlayed"]),
                wins: stats.intStat(anyOf: ["wins", "gamesWon", "matchesWon"]),
                draws: stats.intStat(anyOf: ["ties", "gamesDrawn", "matchesDrawn"]),
                losses: stats.intStat(anyOf: ["losses", "gamesLost", "matchesLost"]),
                goalDifference: stats.intStat(anyOf: ["pointDifferential", "pointsDifference"]),
                points: stats.pointsStat(),
                extra: stats.extra,
                group: group
            )
        case .driver:
            guard let athlete = entry.athlete else { return nil }
            let id = athlete.id ?? athlete.displayName ?? UUID().uuidString
            return SportsStandingRow(
                id: id,
                kind: .driver,
                teamId: nil,
                name: athlete.displayName ?? id,
                rank: stats.rankStat() ?? fallbackRank,
                points: stats.pointsStat(),
                extra: stats.extra,
                group: group
            )
        case .player:
            return nil
        case .constructor:
            let id = entry.team?.id ?? entry.team?.displayName ?? UUID().uuidString
            return SportsStandingRow(
                id: id,
                kind: .constructor,
                teamId: entry.team?.id,
                name: entry.team?.displayName ?? entry.team?.shortDisplayName ?? id,
                rank: stats.rankStat() ?? fallbackRank,
                points: stats.pointsStat(),
                extra: stats.extra,
                group: group
            )
        }
    }

    // MARK: Event detail

    static func mapEventDetail(_ response: ESPNSummaryResponse) -> SportsEventDetail {
        SportsEventDetail(
            keyEvents: (response.keyEvents ?? []).filter(isTimelineWorthy).map(mapKeyEvent),
            teamStats: mapTeamStats(response.boxscore),
            lineups: (response.rosters ?? []).compactMap(mapLineup)
        )
    }

    /// ESPN's soccer feed logs every stoppage as a "Start Delay" / "End Delay"
    /// pair (injuries, VAR checks), each of them twice. They tell the viewer
    /// nothing the clock doesn't, so they never reach the timeline.
    private static func isTimelineWorthy(_ event: ESPNKeyEvent) -> Bool {
        let type = (event.type?.text ?? "").lowercased()
        return !type.contains("delay")
    }

    private static func mapKeyEvent(_ event: ESPNKeyEvent) -> SportsKeyEvent {
        let typeText = event.type?.text ?? ""
        let lowerType = typeText.lowercased()
        let isGoal = (event.scoringPlay ?? false) || lowerType.contains("goal")
        let isCard = (event.yellowCard ?? false) || (event.redCard ?? false) || lowerType.contains("card")
        let isSubstitution = lowerType.contains("substitution")
        var participants = (event.athletesInvolved ?? []).compactMap(\.displayName)
        if participants.isEmpty {
            participants = (event.participants ?? []).compactMap { $0.athlete?.displayName }
        }
        return SportsKeyEvent(
            clock: event.clock?.displayValue ?? "",
            type: typeText,
            typeId: event.type?.id,
            teamId: event.team?.id,
            participants: participants,
            isGoal: isGoal,
            isCard: isCard,
            isSubstitution: isSubstitution
        )
    }

    private static func mapTeamStats(_ boxscore: ESPNBoxscore?) -> [SportsTeamStat] {
        let teams = boxscore?.teams ?? []
        guard teams.count == 2 else { return [] }
        let homeTeam = teams.first { $0.homeAway == "home" } ?? teams[0]
        let awayTeam = teams.first { $0.homeAway == "away" } ?? teams[1]

        var awayByName: [String: ESPNBoxscoreStat] = [:]
        for stat in awayTeam.statistics ?? [] {
            if let name = stat.name { awayByName[name] = stat }
        }

        var result: [SportsTeamStat] = []
        for stat in homeTeam.statistics ?? [] {
            guard let name = stat.name else { continue }
            let away = awayByName[name]
            result.append(
                SportsTeamStat(
                    name: stat.label ?? name,
                    key: name,
                    homeValue: stat.value ?? stat.displayValue.flatMap { Double($0) },
                    awayValue: away?.value ?? away?.displayValue.flatMap { Double($0) },
                    homeDisplay: stat.displayValue ?? "",
                    awayDisplay: away?.displayValue ?? ""
                )
            )
        }
        return result
    }

    private static func mapLineup(_ roster: ESPNRoster) -> SportsLineup? {
        guard let teamId = roster.team?.id else { return nil }
        let starters = (roster.roster ?? [])
            .filter { $0.starter ?? false }
            .compactMap { entry -> SportsLineupPlayer? in
                guard let name = entry.athlete?.displayName else { return nil }
                return SportsLineupPlayer(name: name, jersey: entry.jersey, position: entry.position?.abbreviation)
            }
        return SportsLineup(teamId: teamId, formation: roster.formation, starters: starters)
    }
}

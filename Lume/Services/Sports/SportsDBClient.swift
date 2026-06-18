//
//  SportsDBClient.swift
//  Lume
//
//  Read-only client for TheSportsDB (https://www.thesportsdb.com), which sources
//  the football fixtures behind the Home "Upcoming Matches" row and the team
//  lists in Sports settings.
//
//  TheSportsDB's v1 JSON API works with a free shared test key, so the feature
//  runs out of the box. A personal key (for higher rate limits) can be supplied
//  in the git-ignored `.env` file as SPORTSDB_API_KEY and is injected into
//  Info.plist at build time by Scripts/inject-env.sh — never committed.
//

import Foundation

nonisolated enum SportsDBError: Error {
    case invalidURL
    case invalidResponse
    case serverError(Int)
    case decodingError(Error)
}

/// Read-only TheSportsDB client. Only the endpoints the Upcoming Matches feature
/// needs are implemented: a league's next fixtures, a team's next fixtures, and
/// a league's teams.
nonisolated struct SportsDBClient {
    static let shared = SportsDBClient()

    /// TheSportsDB's free, public test key. Used when no personal key is present
    /// so the feature works without any `.env` configuration.
    static let freeKey = "3"

    private let baseURL = "https://www.thesportsdb.com/api/v1/json"
    private let session: URLSession
    private let key: String

    init(session: URLSession = .shared, key: String? = SportsDBClient.keyFromBundle()) {
        self.session = session
        self.key = key ?? SportsDBClient.freeKey
    }

    /// Always true: the feature falls back to the free shared key, so it is never
    /// hard-disabled for lack of configuration. Kept as a hook for callers that
    /// mirror the other clients' `isConfigured` checks.
    var isConfigured: Bool {
        !key.isEmpty
    }

    static func keyFromBundle() -> String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SportsDBAPIKey") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Guard against an unsubstituted Info.plist variable (no .env present).
        guard let trimmed, !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    // MARK: - Fixtures

    /// The next scheduled fixtures for a league (TheSportsDB returns up to 15).
    func upcomingFixtures(leagueID: String) async throws -> [SportFixture] {
        let events = try await fetchEvents(path: "eventsnextleague.php", query: "id", value: leagueID)
        return events.compactMap(SportFixture.init(event:))
    }

    /// The next scheduled fixtures for a single team (TheSportsDB returns up to 5).
    func upcomingFixtures(teamID: String) async throws -> [SportFixture] {
        let events = try await fetchEvents(path: "eventsnext.php", query: "id", value: teamID)
        return events.compactMap(SportFixture.init(event:))
    }

    // MARK: - Teams

    /// The teams that play in a league, for the Sports settings "Teams" picker.
    /// Filtered to football (soccer), since the catalog is football-only.
    ///
    /// Uses `search_all_teams.php?l=` keyed by the league's canonical name: the
    /// id-based `lookup_all_teams.php?id=` is demo-locked on the free key (it
    /// ignores the id and always returns the same sample league).
    func teams(leagueName: String) async throws -> [SportTeam] {
        guard let url = makeURL(path: "search_all_teams.php", query: "l", value: leagueName) else {
            throw SportsDBError.invalidURL
        }
        let response: TeamsResponse = try await get(url)
        return (response.teams ?? [])
            .filter { ($0.strSport ?? "Soccer").caseInsensitiveCompare("Soccer") == .orderedSame }
            .compactMap(SportTeam.init(team:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Networking

    private func fetchEvents(path: String, query: String, value: String) async throws -> [SportsDBEvent] {
        guard let url = makeURL(path: path, query: query, value: value) else {
            throw SportsDBError.invalidURL
        }
        let response: EventsResponse = try await get(url)
        return response.events ?? []
    }

    private func makeURL(path: String, query: String, value: String) -> URL? {
        var components = URLComponents(string: "\(baseURL)/\(key)/\(path)")
        components?.queryItems = [URLQueryItem(name: query, value: value)]
        return components?.url
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SportsDBError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw SportsDBError.serverError(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SportsDBError.decodingError(error)
        }
    }
}

// MARK: - DTOs

private nonisolated struct EventsResponse: Decodable {
    let events: [SportsDBEvent]?
}

nonisolated struct SportsDBEvent: Decodable {
    let idEvent: String?
    let strEvent: String?
    let strLeague: String?
    let idLeague: String?
    let strHomeTeam: String?
    let strAwayTeam: String?
    let strSport: String?
    let dateEvent: String?
    let strTime: String?
    /// ISO-8601 UTC timestamp (e.g. "2026-08-15T14:00:00+00:00"). Present on most
    /// modern responses; when absent we fall back to `dateEvent` + `strTime`.
    let strTimestamp: String?
}

private nonisolated struct TeamsResponse: Decodable {
    let teams: [SportsDBTeam]?
}

private nonisolated struct SportsDBTeam: Decodable {
    let idTeam: String?
    let strTeam: String?
    let strSport: String?
    /// TheSportsDB renamed the badge field from `strTeamBadge` to `strBadge`; v1
    /// responses still carry the old key, so we accept either.
    let strBadge: String?
    let strTeamBadge: String?
}

// MARK: - DTO → value type

private extension SportFixture {
    nonisolated init?(event: SportsDBEvent) {
        guard let id = event.idEvent,
              let home = event.strHomeTeam, !home.isEmpty,
              let away = event.strAwayTeam, !away.isEmpty,
              let kickoff = SportsDBDate.parse(timestamp: event.strTimestamp, date: event.dateEvent, time: event.strTime)
        else { return nil }
        self.init(
            id: id,
            leagueID: event.idLeague ?? "",
            leagueName: event.strLeague ?? "",
            homeTeam: home,
            awayTeam: away,
            kickoff: kickoff
        )
    }
}

private extension SportTeam {
    nonisolated init?(team: SportsDBTeam) {
        guard let id = team.idTeam, let name = team.strTeam, !name.isEmpty else { return nil }
        let badge = (team.strBadge ?? team.strTeamBadge).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        self.init(id: id, name: name, badgeURL: badge)
    }
}

// MARK: - Date parsing

/// Parses TheSportsDB's event timestamps into a `Date`. Prefers the ISO-8601
/// `strTimestamp`, falling back to the separate UTC `dateEvent` + `strTime`.
///
/// Formatters are built per call rather than cached in statics: this is a
/// `nonisolated` type on a low-volume path (a handful of fixtures), so a fresh
/// formatter sidesteps the Sendable constraints on shared mutable formatters.
nonisolated enum SportsDBDate {
    static func parse(timestamp: String?, date: String?, time: String?) -> Date? {
        if let timestamp, !timestamp.isEmpty {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let parsed = iso.date(from: timestamp) { return parsed }
            // Some rows use a space instead of "T" and omit the zone (UTC).
            if let parsed = utcFormatter().date(from: timestamp.replacingOccurrences(of: "T", with: " ")) {
                return parsed
            }
        }
        guard let date, !date.isEmpty else { return nil }
        let clock = (time?.isEmpty == false ? time! : "00:00:00")
        return utcFormatter().date(from: "\(date) \(clock)")
    }

    private static func utcFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }
}

//
//  SportAnnouncementsService.swift
//  Lume
//
//  Loads upcoming football fixtures for the user's favorite leagues and teams
//  from TheSportsDB, then de-duplicates, filters to the future and sorts them.
//  The EPG/channel matching (the second half of the hybrid) happens in
//  `SportAnnouncementsRow`, which has the model context.
//

import Foundation
import OSLog

@MainActor
@Observable
final class SportAnnouncementsService {
    static let shared = SportAnnouncementsService()

    private(set) var fixtures: [SportFixture] = []
    private(set) var isLoading = false

    /// How far ahead fixtures are kept. TheSportsDB only returns the next handful
    /// per league/team anyway; this just trims anything implausibly far out.
    private let horizon: TimeInterval = 14 * 24 * 3600
    /// Don't refetch more often than this for an unchanged set of favorites.
    private let cacheTTL: TimeInterval = 30 * 60
    private let maxFixtures = 30

    private let client: SportsDBClient
    private var lastLoad: Date?
    private var lastSignature = ""

    init(client: SportsDBClient = .shared) {
        self.client = client
    }

    /// Refreshes `fixtures` for the given favorites. Cheap to call repeatedly: it
    /// no-ops when the favorites and cache window are unchanged unless `force`.
    func refresh(leagueIDs: [String], teamIDs: [String], now: Date = Date(), force: Bool = false) async {
        let signature = (leagueIDs.sorted() + ["|"] + teamIDs.sorted()).joined(separator: ",")
        if leagueIDs.isEmpty, teamIDs.isEmpty {
            fixtures = []
            lastSignature = signature
            return
        }
        if !force, signature == lastSignature, let lastLoad, now.timeIntervalSince(lastLoad) < cacheTTL {
            return
        }

        isLoading = true
        defer { isLoading = false }

        var collected: [String: SportFixture] = [:]
        await withTaskGroup(of: [SportFixture].self) { group in
            for id in leagueIDs {
                group.addTask { [client] in await (try? client.upcomingFixtures(leagueID: id)) ?? [] }
            }
            for id in teamIDs {
                group.addTask { [client] in await (try? client.upcomingFixtures(teamID: id)) ?? [] }
            }
            for await batch in group {
                for fixture in batch {
                    collected[fixture.id] = fixture
                }
            }
        }

        let horizonEnd = now.addingTimeInterval(horizon)
        let upcoming = collected.values
            .filter { $0.kickoff >= now && $0.kickoff <= horizonEnd }
            .sorted { $0.kickoff < $1.kickoff }

        let resolved = Array(upcoming.prefix(maxFixtures))
        fixtures = resolved
        lastLoad = now
        lastSignature = signature
        Logger.sync.debug("Sport announcements: \(resolved.count) upcoming fixtures for \(leagueIDs.count) leagues / \(teamIDs.count) teams")
    }
}

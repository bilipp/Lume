//
//  SportsDataProvider.swift
//  Lume
//
//  The source-agnostic seam for sports data. ESPN's site API is the v1 conformer
//  (a separate file); a second source can be added later without touching the hub.
//  Requirements are `async throws` and the protocol is `nonisolated` so a
//  nonisolated client (or actor) can conform under the project's default
//  MainActor isolation.
//

import Foundation

nonisolated protocol SportsDataProvider: Sendable {
    /// All fixtures for `league` in the given calendar month. `month` need only
    /// carry `year` and `month`; other components are ignored.
    func fixtures(league: SportsLeague, month: DateComponents) async throws -> [SportsFixture]

    /// Fixtures for `league` on a single day — used to refresh live scores.
    func fixtures(league: SportsLeague, day: Date) async throws -> [SportsFixture]

    /// The league's teams, with colours and crests, for the browse-and-follow
    /// picker and to join colours onto standings.
    func teams(league: SportsLeague) async throws -> [SportsTeam]

    /// The league's standings table (or driver/constructor tables for F1).
    func standings(league: SportsLeague) async throws -> [SportsStandingRow]

    /// Timeline, team stats and lineups for one event; `nil` when unavailable.
    func eventDetail(league: SportsLeague, eventId: String) async throws -> SportsEventDetail?
}

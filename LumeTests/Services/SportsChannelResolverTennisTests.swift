//
//  SportsChannelResolverTennisTests.swift
//  LumeTests
//
//  A tennis match is often carried by a tour-wide block that names neither
//  player ("Live ATP & WTA: Die Topspiele des Tages") and started hours before
//  it. That block is offered, below any programme naming the match, and never
//  as one-tap playback.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SportsChannelResolverTennisTests {
    private let playlistID = UUID()
    private let leagueId = SportsLeague.makeID(sport: "tennis", slug: "atp")

    private func player(_ id: String, name: String, short: String) -> SportsCompetitor {
        SportsCompetitor(team: SportsTeam(leagueId: leagueId, teamId: id, name: name, shortName: short, abbreviation: ""))
    }

    private func hurkaczVsShevchenko(at start: Date, tentative: Bool = false) -> SportsFixture {
        SportsFixture(
            id: "atp-\(start.timeIntervalSince1970)",
            leagueId: leagueId,
            leagueName: "ATP Tour",
            leagueAbbreviation: "ATP",
            startDate: start,
            status: SportsFixtureStatus(state: .scheduled),
            home: player("1", name: "Hubert Hurkacz", short: "H. Hurkacz"),
            away: player("2", name: "Alexander Shevchenko", short: "A. Shevchenko"),
            name: "2026 Chengdu Open",
            round: "Round 1",
            startTimeIsTentative: tentative
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let config = ModelConfiguration(schema: OnDiskCatalogStore.catalogSchema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: OnDiskCatalogStore.catalogSchema, configurations: [config])
    }

    private func stream(_ suffix: String, name: String, epgChannelId: String) -> LiveStream {
        LiveStream(
            id: "\(playlistID.uuidString)-live-\(suffix)",
            streamId: Int.random(in: 1 ... 1_000_000),
            name: name,
            epgChannelId: epgChannelId
        )
    }

    private func listing(channelId: String, title: String, subtitle: String = "", start: Date, hours: Double) -> EPGListing {
        EPGListing(
            id: "\(channelId)-\(Int(start.timeIntervalSince1970))",
            channelId: channelId,
            title: title,
            listingDescription: "",
            start: start,
            end: start.addingTimeInterval(hours * 3600),
            subtitle: subtitle,
            category: "Sport"
        )
    }

    private func resolve(_ fixture: SportsFixture, in container: ModelContainer) async -> [ResolvedChannel] {
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [fixture], now: fixture.startDate)
        return result[fixture.id] ?? []
    }

    private let topspiele = "Live ATP & WTA: Die Topspiele des Tages"

    // MARK: - Tests

    @Test func `a tour block on air at the start is suggested but not one-tap`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("sky", name: "Sky Sport Tennis", epgChannelId: "skytennis.de"))
        let start = Date()
        context.insert(listing(
            channelId: "skytennis.de", title: topspiele, start: start.addingTimeInterval(-5 * 3600), hours: 8
        ))
        try context.save()

        let channels = await resolve(hurkaczVsShevchenko(at: start), in: container)
        #expect(channels.map(\.stream.name) == ["Sky Sport Tennis"])
        #expect(channels.first?.source == .epgCompetition)
        #expect(channels.first?.matchedTitle == topspiele)
        #expect(channels.first?.isConfident == false)
    }

    @Test func `a programme naming the match ranks above the tour block`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("sky", name: "Sky Sport Tennis", epgChannelId: "skytennis.de"))
        context.insert(stream("tv", name: "Tennis Channel", epgChannelId: "tc.us"))
        let start = Date()
        context.insert(listing(
            channelId: "skytennis.de", title: topspiele, start: start.addingTimeInterval(-5 * 3600), hours: 8
        ))
        context.insert(listing(
            channelId: "tc.us", title: "ATP Chengdu", subtitle: "Hurkacz vs Shevchenko", start: start, hours: 2
        ))
        try context.save()

        let channels = await resolve(hurkaczVsShevchenko(at: start), in: container)
        #expect(channels.map(\.source) == [.epgTitleSubtitle, .epgCompetition])
        #expect(channels.first?.isConfident == true)
    }

    @Test func `the other tour's block and a finished block are not offered`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("wta", name: "WTA TV", epgChannelId: "wta.tv"))
        context.insert(stream("sky", name: "Sky Sport Tennis", epgChannelId: "skytennis.de"))
        let start = Date()
        context.insert(listing(
            channelId: "wta.tv", title: "Live WTA: Wuhan Open", start: start.addingTimeInterval(-3600), hours: 4
        ))
        context.insert(listing(
            channelId: "skytennis.de", title: topspiele, start: start.addingTimeInterval(-6 * 3600), hours: 5
        ))
        try context.save()

        let channels = await resolve(hurkaczVsShevchenko(at: start), in: container)
        #expect(channels.isEmpty)
    }

    @Test func `a match without a time slot is not tied to a tour block`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("sky", name: "Sky Sport Tennis", epgChannelId: "skytennis.de"))
        let start = Date()
        context.insert(listing(
            channelId: "skytennis.de", title: topspiele, start: start.addingTimeInterval(-3600), hours: 8
        ))
        try context.save()

        let channels = await resolve(hurkaczVsShevchenko(at: start, tentative: true), in: container)
        #expect(channels.isEmpty)
    }

    @Test func `tournament tokens drop years and generic words`() {
        #expect(SportsCompetitionMatcher.tournamentTokens("2026 AITO Hangzhou Open") == ["aito", "hangzhou"])
        #expect(SportsCompetitionMatcher.tournamentTokens("2026 Chengdu Open") == ["chengdu"])
    }
}

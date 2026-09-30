//
//  SportsChannelResolverIndexTests.swift
//  LumeTests
//
//  The resolver reads the guide only around each kickoff and scores only the
//  channels its word index names. These pin the parts that are new: window
//  merging, a batch spread across a week, and picks found through the index.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SportsChannelResolverIndexTests {
    private let leagueId = "espn:soccer/ger.1"
    private let playlistID = UUID()

    private func fixture(_ id: String, home: String, away: String, kickoff: Date) -> SportsFixture {
        SportsFixture(
            id: id,
            leagueId: leagueId,
            leagueName: "Bundesliga",
            leagueAbbreviation: "BUND",
            startDate: kickoff,
            status: SportsFixtureStatus(state: .scheduled),
            home: SportsCompetitor(team: SportsTeam(leagueId: leagueId, teamId: "h-\(id)", name: home, shortName: home, abbreviation: "")),
            away: SportsCompetitor(team: SportsTeam(leagueId: leagueId, teamId: "a-\(id)", name: away, shortName: away, abbreviation: ""))
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: OnDiskCatalogStore.catalogSchema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: OnDiskCatalogStore.catalogSchema, configurations: [config])
    }

    private func insertStream(_ suffix: String, name: String, epgChannelId: String?, in context: ModelContext) {
        context.insert(LiveStream(
            id: "\(playlistID.uuidString)-live-\(suffix)",
            streamId: Int.random(in: 1 ... 1_000_000),
            name: name,
            epgChannelId: epgChannelId
        ))
    }

    private func insertListing(channelId: String, subtitle: String, start: Date, in context: ModelContext) {
        context.insert(EPGListing(
            id: "\(channelId)-\(Int(start.timeIntervalSince1970))",
            channelId: channelId,
            title: "Bundesliga",
            listingDescription: "",
            start: start,
            end: start.addingTimeInterval(2 * 3600),
            subtitle: subtitle,
            category: "Sport"
        ))
    }

    /// The implementation `SportsMatcher.normalize` replaced, kept as the
    /// reference its one-pass rewrite must agree with.
    private func referenceNormalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let cleaned = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return " \(String(cleaned).split(separator: " ").joined(separator: " ")) "
    }

    @Test(arguments: [
        "", " ", "Bayern", "FC Bayern München – Borussia Dortmund", "  Live:  F1 / Qualifying!! ",
        "1. Freies Training", "Atlético de Madrid", "Sky Sport 1 HD (DE)", "ÀÉÎÕÜ çñ", "a|b|c", "123-456"
    ])
    func `normalize matches the reference implementation`(text: String) {
        #expect(SportsMatcher.normalize(text) == referenceNormalize(text))
    }

    @Test func `overlapping kickoff windows merge and distant ones stay apart`() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let fixtures = [
            fixture("a", home: "Bayern", away: "Dortmund", kickoff: base),
            fixture("b", home: "Leipzig", away: "Bremen", kickoff: base.addingTimeInterval(3600)),
            fixture("c", home: "Mainz", away: "Koeln", kickoff: base.addingTimeInterval(6 * 86400))
        ]

        let windows = SportsChannelResolver.guideWindows(for: fixtures)

        #expect(windows.count == 2)
        #expect(windows[0].lowerBound == base.addingTimeInterval(-SportsMatcher.leadTime))
        #expect(windows[0].upperBound == base.addingTimeInterval(3600 + SportsMatcher.lateStart))
        #expect(windows[1].lowerBound == base.addingTimeInterval(6 * 86400 - SportsMatcher.leadTime))
    }

    @Test func `fixtures a week apart each resolve from their own window`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let today = Date()
        let nextWeek = today.addingTimeInterval(6 * 86400)
        insertStream("sky", name: "Sky Bundesliga", epgChannelId: "sky.de", in: context)
        insertStream("dazn", name: "DAZN 1", epgChannelId: "dazn.de", in: context)
        // Decoys that name neither fixture's teams.
        for index in 0 ..< 50 {
            insertStream("decoy\(index)", name: "Channel \(index)", epgChannelId: "decoy\(index).de", in: context)
            insertListing(channelId: "decoy\(index).de", subtitle: "Cooking Show", start: today, in: context)
        }
        insertListing(channelId: "sky.de", subtitle: "Bayern vs Dortmund", start: today, in: context)
        insertListing(channelId: "dazn.de", subtitle: "Mainz vs Koeln", start: nextWeek, in: context)
        try context.save()

        let first = fixture("today", home: "Bayern", away: "Dortmund", kickoff: today)
        let second = fixture("later", home: "Mainz", away: "Koeln", kickoff: nextWeek)
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [first, second], now: today)

        #expect(result[first.id]?.map(\.stream.epgChannelId) == ["sky.de"])
        #expect(result[second.id]?.map(\.stream.epgChannelId) == ["dazn.de"])
    }

    @Test func `a pick on a channel named with a separator is found`() async throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let picks = SportsChannelPicks(defaults: defaults)
        let container = try makeContainer()
        let context = ModelContext(container)
        // No EPG id, so the pick keys off the folded name, which keeps its "|".
        insertStream("pick", name: "DE | Sport Extra", epgChannelId: nil, in: context)
        try context.save()
        picks.remember(
            competitionKey: leagueId,
            channelKey: SportsChannelPicks.channelKey(epgChannelId: nil, name: "DE | Sport Extra"),
            playlistID: playlistID
        )

        let game = fixture("pick", home: "Bayern", away: "Dortmund", kickoff: Date())
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [game], now: Date(), picks: picks)

        #expect(result[game.id]?.first?.source == .userPick)
        #expect(result[game.id]?.first?.stream.name == "DE | Sport Extra")
    }
}

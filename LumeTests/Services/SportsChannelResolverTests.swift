//
//  SportsChannelResolverTests.swift
//  LumeTests
//
//  Exercises the off-main fixture→channel resolver against a real store file
//  (SQLite, not in-memory: the candidate fetch uses `starts(with:)`-style
//  predicates and a partial `propertiesToFetch`, both of which an in-memory
//  store evaluates in Swift and so cannot prove). Covers exclusion of hidden and
//  restricted channels, the kickoff-window bound, the source-tier ordering,
//  channel-name fallback, remembered picks, and single-vs-ambiguous confidence.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SportsChannelResolverTests {
    private let leagueId = "espn:soccer/ger.1"
    private let playlistID = UUID()

    // MARK: - Fixtures

    private func makeTeam(_ id: String, name: String, short: String, abbr: String) -> SportsTeam {
        SportsTeam(leagueId: leagueId, teamId: id, name: name, shortName: short, abbreviation: abbr)
    }

    private func bayernVsDortmund(kickoff: Date, state: SportsFixtureState = .scheduled) -> SportsFixture {
        SportsFixture(
            id: "evt-\(kickoff.timeIntervalSince1970)",
            leagueId: leagueId,
            leagueName: "Bundesliga",
            leagueAbbreviation: "BUND",
            startDate: kickoff,
            status: SportsFixtureStatus(state: state),
            home: SportsCompetitor(team: makeTeam("132", name: "Bayern Munich", short: "Bayern", abbr: "FCB")),
            away: SportsCompetitor(team: makeTeam("124", name: "Borussia Dortmund", short: "Dortmund", abbr: "BVB"))
        )
    }

    // MARK: - Store

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

    private func stream(
        _ suffix: String,
        name: String,
        epgChannelId: String?,
        categoryId: String? = nil,
        isHidden: Bool = false
    ) -> LiveStream {
        let stream = LiveStream(
            id: "\(playlistID.uuidString)-live-\(suffix)",
            streamId: Int.random(in: 1 ... 1_000_000),
            name: name,
            epgChannelId: epgChannelId,
            categoryId: categoryId
        )
        stream.isHidden = isHidden
        return stream
    }

    private func listing(
        channelId: String,
        title: String,
        subtitle: String,
        start: Date,
        hours: Double = 2,
        description: String = ""
    ) -> EPGListing {
        EPGListing(
            id: "\(channelId)-\(Int(start.timeIntervalSince1970))",
            channelId: channelId,
            title: title,
            listingDescription: description,
            start: start,
            end: start.addingTimeInterval(hours * 3600),
            subtitle: subtitle,
            category: "Sport"
        )
    }

    // MARK: - Tests

    @Test func `single EPG match resolves to one confident channel`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("1", name: "Sky Bundesliga", epgChannelId: "sky.de"))
        let kickoff = Date()
        context.insert(listing(channelId: "sky.de", title: "Bundesliga", subtitle: "Bayern vs Dortmund", start: kickoff))
        try context.save()

        let fixture = bayernVsDortmund(kickoff: kickoff)
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [fixture], now: kickoff)

        let channels = try #require(result[fixture.id])
        #expect(channels.count == 1)
        #expect(channels[0].source == .epgTitleSubtitle)
        #expect(channels[0].isConfident)
        #expect(channels[0].playlistID == playlistID)
        #expect(channels[0].matchedTitle == "Bundesliga")
    }

    @Test func `a conference naming both teams in its description is suggested`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("1", name: "Sky Bundesliga HDraw", epgChannelId: "sky.konf"))
        let kickoff = Date()
        context.insert(listing(
            channelId: "sky.konf",
            title: "Live BL: Sonntags-Konferenz, 6. Spieltag",
            subtitle: "",
            start: kickoff,
            description: "Der 6. Spieltag mit FC Bayern München - Borussia Dortmund, Hannover 96 - VfL Bochum "
                + "und Energie Cottbus - FC St. Pauli. Moderation: Yannick Erkenbrecher."
        ))
        try context.save()

        let fixture = bayernVsDortmund(kickoff: kickoff)
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [fixture], now: kickoff)

        let channels = try #require(result[fixture.id])
        #expect(channels.count == 1)
        #expect(channels[0].source == .epgDescription)
        #expect(channels[0].matchedTitle == "Live BL: Sonntags-Konferenz, 6. Spieltag")
    }

    @Test func `a dedicated broadcast ranks above the conference`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("1", name: "Sky Bundesliga HDraw", epgChannelId: "sky.konf"))
        context.insert(stream("2", name: "Sky Bundesliga 2", epgChannelId: "sky.2"))
        let kickoff = Date()
        context.insert(listing(
            channelId: "sky.konf", title: "Live BL: Konferenz", subtitle: "", start: kickoff,
            description: "Mit Bayern München - Borussia Dortmund und Hannover 96 - VfL Bochum."
        ))
        context.insert(listing(channelId: "sky.2", title: "Live BL", subtitle: "Bayern München - Borussia Dortmund", start: kickoff))
        try context.save()

        let fixture = bayernVsDortmund(kickoff: kickoff)
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [fixture], now: kickoff)

        let channels = try #require(result[fixture.id])
        #expect(channels.map(\.source) == [.epgTitleSubtitle, .epgDescription])
        #expect(channels[0].stream.name == "Sky Bundesliga 2")
        #expect(channels[0].isConfident, "the dedicated broadcast alone holds the strongest tier")
    }

    @Test func `a description naming only one team is not a match`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("1", name: "Sky Bundesliga HDraw", epgChannelId: "sky.konf"))
        let kickoff = Date()
        context.insert(listing(
            channelId: "sky.konf", title: "Live BL: Konferenz", subtitle: "", start: kickoff,
            description: "Mit Bayern München - VfL Bochum und Hannover 96 - FC St. Pauli."
        ))
        try context.save()

        let fixture = bayernVsDortmund(kickoff: kickoff)
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [fixture], now: kickoff)

        #expect((result[fixture.id] ?? []).isEmpty)
    }

    @Test func `two matching channels are ambiguous, neither confident`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("1", name: "Sky Bundesliga", epgChannelId: "sky.de"))
        context.insert(stream("2", name: "DAZN 1", epgChannelId: "dazn.de"))
        let kickoff = Date()
        context.insert(listing(channelId: "sky.de", title: "Bundesliga", subtitle: "Bayern vs Dortmund", start: kickoff))
        context.insert(listing(channelId: "dazn.de", title: "Fußball", subtitle: "Bayern vs Dortmund", start: kickoff))
        try context.save()

        let fixture = bayernVsDortmund(kickoff: kickoff)
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [fixture], now: kickoff)

        let channels = try #require(result[fixture.id])
        #expect(channels.count == 2)
        #expect(channels.allSatisfy { !$0.isConfident })
    }

    @Test func `hidden channels and restricted categories are excluded`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("visible", name: "Sky Bundesliga", epgChannelId: "sky.de"))
        context.insert(stream("hidden", name: "Sky Bundesliga HD", epgChannelId: "skyhd.de", isHidden: true))
        context.insert(stream("locked", name: "Sky Bundesliga 4K", epgChannelId: "sky4k.de", categoryId: "adult-cat"))
        let kickoff = Date()
        for cid in ["sky.de", "skyhd.de", "sky4k.de"] {
            context.insert(listing(channelId: cid, title: "Bundesliga", subtitle: "Bayern vs Dortmund", start: kickoff))
        }
        try context.save()

        let fixture = bayernVsDortmund(kickoff: kickoff)
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["adult-cat"])
        let result = await SportsChannelResolver.resolve(
            container: container, fixtures: [fixture], now: kickoff, restriction: restriction
        )

        let channels = try #require(result[fixture.id])
        #expect(channels.map(\.stream.epgChannelId) == ["sky.de"])
    }

    @Test func `a programme outside the kickoff window is not matched`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("1", name: "Sky Bundesliga", epgChannelId: "sky.de"))
        let kickoff = Date()
        // Starts three hours after kickoff — past the 30-minute late-start bound.
        context.insert(listing(
            channelId: "sky.de", title: "Bundesliga", subtitle: "Bayern vs Dortmund",
            start: kickoff.addingTimeInterval(3 * 3600)
        ))
        try context.save()

        let fixture = bayernVsDortmund(kickoff: kickoff)
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [fixture], now: kickoff)
        #expect(result[fixture.id]?.isEmpty == true)
    }

    @Test func `channel name naming both teams is a fallback candidate`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("1", name: "DAZN 5 | Bayern vs Dortmund", epgChannelId: nil))
        try context.save()

        let kickoff = Date()
        let fixture = bayernVsDortmund(kickoff: kickoff)
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [fixture], now: kickoff)

        let channels = try #require(result[fixture.id])
        #expect(channels.count == 1)
        #expect(channels[0].source == .channelName)
    }

    @Test func `a user pick ranks above an EPG match`() async throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let picks = SportsChannelPicks(defaults: defaults)

        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("epg", name: "Sky Bundesliga", epgChannelId: "sky.de"))
        context.insert(stream("pick", name: "My Sports Channel", epgChannelId: "mine.de"))
        let kickoff = Date()
        context.insert(listing(channelId: "sky.de", title: "Bundesliga", subtitle: "Bayern vs Dortmund", start: kickoff))
        try context.save()

        picks.remember(competitionKey: leagueId, channelKey: "mine.de", playlistID: playlistID)

        let fixture = bayernVsDortmund(kickoff: kickoff)
        let result = await SportsChannelResolver.resolve(
            container: container, fixtures: [fixture], now: kickoff, picks: picks
        )

        let channels = try #require(result[fixture.id])
        #expect(channels.first?.source == .userPick)
        #expect(channels.first?.stream.epgChannelId == "mine.de")
        #expect(channels.first?.isConfident == true)
    }
}

// MARK: - Picks store

@MainActor
struct SportsChannelPicksTests {
    private func store() throws -> SportsChannelPicks {
        try SportsChannelPicks(defaults: #require(UserDefaults(suiteName: UUID().uuidString)))
    }

    @Test func `a pick persists and reports as picked`() throws {
        let picks = try store()
        let playlistID = UUID()
        picks.remember(competitionKey: "espn:soccer/ger.1", channelKey: "sky.de", playlistID: playlistID)
        #expect(picks.isPicked(competitionKey: "espn:soccer/ger.1", channelKey: "sky.de"))
        #expect(!picks.isPicked(competitionKey: "espn:soccer/eng.1", channelKey: "sky.de"))
    }

    @Test func `removing a playlist prunes only its picks`() throws {
        let picks = try store()
        let mine = UUID()
        let theirs = UUID()
        picks.remember(competitionKey: "espn:soccer/ger.1", channelKey: "sky.de", playlistID: mine)
        picks.remember(competitionKey: "espn:soccer/ger.1", channelKey: "dazn.de", playlistID: theirs)

        picks.remove(playlistID: mine)

        #expect(!picks.isPicked(competitionKey: "espn:soccer/ger.1", channelKey: "sky.de"))
        #expect(picks.isPicked(competitionKey: "espn:soccer/ger.1", channelKey: "dazn.de"))
    }

    @Test func `channel key falls back to the folded name when there is no epg id`() {
        #expect(SportsChannelPicks.channelKey(epgChannelId: "sky.de", name: "Sky") == "sky.de")
        #expect(SportsChannelPicks.channelKey(epgChannelId: nil, name: "Sky Bundesliga") == "sky bundesliga")
        #expect(SportsChannelPicks.channelKey(epgChannelId: "  ", name: "Kabel Eins") == "kabel eins")
    }
}

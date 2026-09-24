//
//  SportsChannelResolverRacingTests.swift
//  LumeTests
//
//  Race sessions have no two teams: they resolve on the series and the session
//  named in the guide. Titles are real ones from German/Austrian EPGs.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SportsChannelResolverRacingTests {
    private let playlistID = UUID()

    /// The Azerbaijan weekend as ESPN serves it, expanded to the card for `kind`.
    private func session(_ kind: SportsSessionKind, at start: Date) throws -> SportsFixture {
        let offsets: [SportsSessionKind: TimeInterval] = [
            .fp1: 0, .fp2: 3.5 * 3600, .fp3: 24 * 3600, .qualifying: 27.5 * 3600, .race: 50.5 * 3600
        ]
        let fp1 = start.addingTimeInterval(-(offsets[kind] ?? 0))
        let sessions = [SportsSessionKind.fp1, .fp2, .fp3, .qualifying, .race].map {
            SportsSession(kind: $0, date: fp1.addingTimeInterval(offsets[$0] ?? 0))
        }
        let weekend = SportsFixture(
            id: "600057444",
            leagueId: "espn:racing/f1",
            leagueName: "Formula 1",
            leagueAbbreviation: "F1",
            startDate: fp1,
            status: SportsFixtureStatus(state: .inProgress),
            sessions: sessions,
            name: "Qatar Airways Azerbaijan Grand Prix"
        )
        return try #require(weekend.expandedBySession(now: start).first { $0.sessionKind == kind })
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

    private func stream(_ suffix: String, name: String, epgChannelId: String?) -> LiveStream {
        LiveStream(
            id: "\(playlistID.uuidString)-live-\(suffix)",
            streamId: Int.random(in: 1 ... 1_000_000),
            name: name,
            epgChannelId: epgChannelId
        )
    }

    private func listing(channelId: String, title: String, start: Date, hours: Double = 1.5) -> EPGListing {
        EPGListing(
            id: "\(channelId)-\(Int(start.timeIntervalSince1970))",
            channelId: channelId,
            title: title,
            listingDescription: "",
            start: start,
            end: start.addingTimeInterval(hours * 3600),
            subtitle: nil,
            category: "Sport"
        )
    }

    private func resolve(_ fixture: SportsFixture, in container: ModelContainer) async -> [ResolvedChannel] {
        let result = await SportsChannelResolver.resolve(
            container: container, fixtures: [fixture], now: fixture.startDate
        )
        return result[fixture.id] ?? []
    }

    // MARK: - Tests

    @Test func `a guide title naming series and session resolves confidently`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("sky", name: "Sky Sports F1", epgChannelId: "skyf1.de"))
        let start = Date()
        context.insert(listing(
            channelId: "skyf1.de", title: "Live F1: 1. Freies Training - GP Aserbaidschan",
            start: start.addingTimeInterval(-15 * 60)
        ))
        try context.save()

        let channels = try await resolve(session(.fp1, at: start), in: container)
        #expect(channels.count == 1)
        #expect(channels.first?.source == .epgTitleSubtitle)
        #expect(channels.first?.isConfident == true)
    }

    @Test func `a series-only title is suggested below the session broadcast`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("sky", name: "Sky Sports F1", epgChannelId: "skyf1.de"))
        context.insert(stream("servus", name: "Servus TV AT", epgChannelId: "servus.at"))
        let start = Date()
        context.insert(listing(channelId: "skyf1.de", title: "Live F1: Das Rennen - GP Aserbaidschan", start: start))
        context.insert(listing(
            channelId: "servus.at", title: "Formel 1 - Qatar Airways Grand Prix von Aserbaidschan",
            start: start.addingTimeInterval(-3600), hours: 3.5
        ))
        try context.save()

        let channels = try await resolve(session(.race, at: start), in: container)
        #expect(channels.map(\.stream.name) == ["Sky Sports F1", "Servus TV AT"])
        #expect(channels.map(\.source) == [.epgTitleSubtitle, .epgSingleField])
        #expect(channels.first?.isConfident == true)
    }

    @Test func `a series-only title alone is a confident match`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("servus", name: "Servus TV AT", epgChannelId: "servus.at"))
        let start = Date()
        context.insert(listing(
            channelId: "servus.at", title: "Formel 1 - Qatar Airways Grand Prix von Aserbaidschan", start: start
        ))
        try context.save()

        let channels = try await resolve(session(.race, at: start), in: container)
        #expect(channels.map(\.source) == [.epgSingleField])
        #expect(channels.first?.isConfident == true)
    }

    @Test func `a programme naming another session is not offered`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("sky", name: "Sky Sport Mix", epgChannelId: "mix.de"))
        let start = Date()
        // FP1 replay an hour before FP2.
        context.insert(listing(
            channelId: "mix.de", title: "F1: 1. Freies Training - GP Aserbaidschan (Wh.)",
            start: start.addingTimeInterval(-3600)
        ))
        try context.save()

        let channels = try await resolve(session(.fp2, at: start), in: container)
        #expect(channels.isEmpty)
    }

    @Test func `a feeder series on the F1 channel is not the session`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("sky", name: "Sky Sports F1", epgChannelId: "skyf1.de"))
        let start = Date()
        context.insert(listing(channelId: "skyf1.de", title: "Live F2: Qualifying - GP Aserbaidschan", start: start))
        try context.save()

        let channels = try await resolve(session(.qualifying, at: start), in: container)
        #expect(channels.isEmpty, "Sky Sports F1 is airing F2, so neither the guide nor its name offers it")
    }

    @Test func `a series-named channel without guide data is a fallback`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(stream("sky", name: "Sky Sports F1 HD", epgChannelId: nil))
        context.insert(stream("news", name: "Sky News", epgChannelId: nil))
        try context.save()

        let channels = try await resolve(session(.fp1, at: Date()), in: container)
        #expect(channels.map(\.stream.name) == ["Sky Sports F1 HD"])
        #expect(channels.first?.source == .channelName)
    }

    @Test(arguments: [
        ("Live F1: 1. Freies Training", Set([SportsSessionKind.fp1])),
        ("Formel 1: Training", Set([.fp1, .fp2, .fp3])),
        ("Formula 1: Azerbaijan GP Practice Two", Set([.fp2])),
        ("F1: Sprint-Qualifying", Set([.sprintQualifying])),
        ("Formel 1 - Sprint", Set([.sprint])),
        ("Live F1: Qualifying", Set([.qualifying])),
        ("Live F1: Das Rennen", Set([.race])),
        ("Formel 1 - Qatar Airways Grand Prix von Aserbaidschan", Set<SportsSessionKind>())
    ])
    func `session words are read off guide titles`(title: String, expected: Set<SportsSessionKind>) {
        let series = SportsRaceMatcher.seriesPhrases(leagueId: "espn:racing/f1")
        #expect(SportsRaceMatcher.sessions(in: SportsMatcher.normalize(title), ignoring: series) == expected)
    }
}

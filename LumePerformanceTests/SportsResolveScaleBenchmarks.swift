//
//  SportsResolveScaleBenchmarks.swift
//  LumePerformanceTests
//
//  The fixture→channel resolve at the scale a large provider reaches: 57,000
//  channels sharing 7,000 guide ids, a week of guide (about 210,000 listings)
//  and 200 fixtures spread across that week — the hub's Upcoming list for a
//  viewer following four US leagues. `SportsQueryBenchmarks` (400 channels, one
//  fixture) cannot see a per-channel-per-fixture blow-up or a guide window that
//  grows with the batch's span; this can.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

final class SportsResolveScaleBenchmarks: XCTestCase {
    private var store: (container: ModelContainer, directory: URL)!
    private let playlistID = UUID()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private let guideChannels = 7000
    private let streamsPerGuideChannel = 8
    private let listingsPerChannel = 30
    private let fixtureCount = 200

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try PerfStore.makeOnDiskContainer()
        seed()
    }

    override func tearDownWithError() throws {
        if let store {
            PerfStore.destroy(directory: store.directory)
        }
        store = nil
        try super.tearDownWithError()
    }

    func testSportsResolve200FixturesOver57kChannels() {
        let fixtures = makeFixtures()

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            // Cold: without this, every run after the first is a cache hit.
            SportsChannelResolver.ResolveCache.shared.removeAll()
            let result = resolveSynchronously(fixtures: fixtures)
            // Each fixture is carried by the streams of exactly one guide channel.
            XCTAssertEqual(result[fixtures[0].id]?.count, streamsPerGuideChannel)
            XCTAssertEqual(result[fixtures[fixtureCount - 1].id]?.count, streamsPerGuideChannel)
        }
    }

    /// The same batch resolved again under an unchanged catalog: what a Sports
    /// surface pays when its `.task(id:)` re-runs, or a second surface asks for
    /// fixtures the first already resolved.
    func testSportsResolveWarmCache() {
        let fixtures = makeFixtures()
        SportsChannelResolver.ResolveCache.shared.removeAll()
        _ = resolveSynchronously(fixtures: fixtures)

        measure(metrics: [XCTClockMetric()]) {
            let result = resolveSynchronously(fixtures: fixtures)
            XCTAssertEqual(result[fixtures[0].id]?.count, streamsPerGuideChannel)
        }
    }

    // MARK: - Fixtures

    private func kickoff(_ index: Int) -> Date {
        // Spread over seven days, a few hours apart, like a week of evening games.
        start.addingTimeInterval(Double(index) * (7 * 86400) / Double(fixtureCount))
    }

    private func makeFixtures() -> [SportsFixture] {
        (0 ..< fixtureCount).map { index in
            SportsFixture(
                id: "evt-\(index)",
                leagueId: "espn:basketball/nba",
                leagueName: "NBA",
                leagueAbbreviation: "NBA",
                startDate: kickoff(index),
                status: SportsFixtureStatus(state: .scheduled),
                home: SportsCompetitor(team: SportsTeam(
                    leagueId: "espn:basketball/nba", teamId: "h\(index)",
                    name: "Homeside\(index)", shortName: "Homeside\(index)", abbreviation: ""
                )),
                away: SportsCompetitor(team: SportsTeam(
                    leagueId: "espn:basketball/nba", teamId: "a\(index)",
                    name: "Awayside\(index)", shortName: "Awayside\(index)", abbreviation: ""
                ))
            )
        }
    }

    // MARK: - Resolve

    private func resolveSynchronously(fixtures: [SportsFixture]) -> [String: [ResolvedChannel]] {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let container = store.container
        let now = start
        Task.detached {
            box.value = await SportsChannelResolver.resolve(container: container, fixtures: fixtures, now: now)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        var value: [String: [ResolvedChannel]] = [:]
    }

    // MARK: - Seed

    private func seed() {
        let context = ModelContext(store.container)
        context.autosaveEnabled = false
        let spacing = 7 * 86400 / Double(listingsPerChannel)
        for channel in 0 ..< guideChannels {
            autoreleasepool {
                let channelID = "guide\(channel)"
                for copy in 0 ..< streamsPerGuideChannel {
                    let index = channel * streamsPerGuideChannel + copy
                    context.insert(LiveStream(
                        id: "\(playlistID.uuidString)-live-\(index)",
                        streamId: index,
                        name: "Channel \(channel) Feed \(copy)",
                        epgChannelId: channelID,
                        categoryId: nil
                    ))
                }
                for slot in 0 ..< listingsPerChannel {
                    let when = start.addingTimeInterval(Double(slot) * spacing)
                    context.insert(EPGListing(
                        id: "\(channelID)-\(slot)",
                        channelId: channelID,
                        title: "Programme \(slot)",
                        listingDescription: "An evening of highlights, analysis and interviews from around the league.",
                        start: when,
                        end: when.addingTimeInterval(spacing),
                        subtitle: "Episode \(slot)",
                        category: "Sport"
                    ))
                }
                if channel.isMultiple(of: 500) { try? context.save() }
            }
        }
        // One guide channel carries each fixture, as its own programme.
        for index in 0 ..< fixtureCount {
            let channelID = "guide\(index)"
            context.insert(EPGListing(
                id: "\(channelID)-fixture-\(index)",
                channelId: channelID,
                title: "NBA",
                listingDescription: "",
                start: kickoff(index),
                end: kickoff(index).addingTimeInterval(3 * 3600),
                subtitle: "Homeside\(index) vs Awayside\(index)",
                category: "Sport"
            ))
        }
        try? context.save()
    }
}

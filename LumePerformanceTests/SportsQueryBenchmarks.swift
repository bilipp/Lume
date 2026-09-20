//
//  SportsQueryBenchmarks.swift
//  LumePerformanceTests
//
//  The off-main fixture→channel resolve, measured at the scale a mid-size
//  playlist reaches. Like `EPGQueryBenchmarks`, it seeds a realistic catalog
//  once (outside the measured region) and times only the resolve — two bounded
//  catalog fetches plus the in-Swift match across every visible channel.
//
//  This is the regression guard on the resolver staying scoped: an unbounded
//  guide scan or a per-channel-per-fixture blow-up would show here first.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

final class SportsQueryBenchmarks: XCTestCase {
    private var store: (container: ModelContainer, directory: URL)!
    private let channelCount = 400
    private let playlistID = UUID()
    private let kickoff = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try PerfStore.makeOnDiskContainer()
        seedChannels()
    }

    override func tearDownWithError() throws {
        if let store {
            PerfStore.destroy(directory: store.directory)
        }
        store = nil
        try super.tearDownWithError()
    }

    /// One fixture resolved against a 400-channel playlist whose guide names the
    /// fixture on every channel — the pessimistic upper bound, where the matcher
    /// runs its full token check for each channel.
    func testSportsResolveOver400Channels() {
        let fixture = makeFixture()

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let result = resolveSynchronously(fixtures: [fixture])
            XCTAssertEqual(result[fixture.id]?.count, channelCount)
        }
    }

    // MARK: - Helpers

    private func makeFixture() -> SportsFixture {
        SportsFixture(
            id: "evt-1",
            leagueId: "espn:soccer/ger.1",
            leagueName: "Bundesliga",
            leagueAbbreviation: "BUND",
            startDate: kickoff,
            status: SportsFixtureStatus(state: .inProgress),
            home: SportsCompetitor(team: SportsTeam(
                leagueId: "espn:soccer/ger.1", teamId: "132",
                name: "Bayern Munich", shortName: "Bayern", abbreviation: "FCB"
            )),
            away: SportsCompetitor(team: SportsTeam(
                leagueId: "espn:soccer/ger.1", teamId: "124",
                name: "Borussia Dortmund", shortName: "Dortmund", abbreviation: "BVB"
            ))
        )
    }

    /// XCTest's `measure` block is synchronous; the resolver is `async`, so run
    /// it on a detached task and block the caller on a semaphore. Detached (not a
    /// plain `Task`) so it never needs the actor `semaphore.wait()` is parked on
    /// — the locals it captures are all `Sendable`.
    private func resolveSynchronously(fixtures: [SportsFixture]) -> [String: [ResolvedChannel]] {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let container = store.container
        let when = kickoff
        Task.detached {
            box.value = await SportsChannelResolver.resolve(container: container, fixtures: fixtures, now: when)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        var value: [String: [ResolvedChannel]] = [:]
    }

    private func seedChannels() {
        let context = ModelContext(store.container)
        context.autosaveEnabled = false
        for index in 0 ..< channelCount {
            autoreleasepool {
                let channelID = "ch\(index)"
                context.insert(LiveStream(
                    id: "\(playlistID.uuidString)-live-\(index)",
                    streamId: index,
                    name: "Sports Channel \(index)",
                    epgChannelId: channelID,
                    categoryId: nil
                ))
                context.insert(EPGListing(
                    id: "\(channelID)-listing",
                    channelId: channelID,
                    title: "Bundesliga",
                    listingDescription: "A synthetic description; the resolver reads its head for conference games.",
                    start: kickoff,
                    end: kickoff.addingTimeInterval(2 * 3600),
                    subtitle: "Bayern vs Dortmund",
                    category: "Sport"
                ))
            }
        }
        try? context.save()
    }
}

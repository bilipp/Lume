//
//  WatchProgressWriterLiveTests.swift
//  LumeTests
//
//  A channel zap holds its "recently watched" touch instead of saving while the
//  next stream opens; the player's next unheld write stamps every channel the
//  session visited, in one save.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct WatchProgressWriterLiveTests {
    private func makeChannels(_ count: Int) throws -> (ModelContainer, [String]) {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let prefix = UUID().uuidString
        let ids = (0 ..< count).map { "\(prefix)-live-\($0)" }
        for (index, id) in ids.enumerated() {
            context.insert(LiveStream(id: id, streamId: index, name: "Channel \(index)"))
        }
        try context.save()
        return (container, ids)
    }

    private func lastWatched(_ id: String, in container: ModelContainer) throws -> Date? {
        let descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        return try ModelContext(container).fetch(descriptor).first?.lastWatchedDate
    }

    @Test func `a held zap writes nothing until the next unheld write`() async throws {
        let (container, ids) = try makeChannels(3)
        let writer = WatchProgressWriter(container: container)

        await writer.record(ref: .live(ids[0]), progress: 5, duration: 0, force: true, holdLive: true)
        await writer.record(ref: .live(ids[1]), progress: 5, duration: 0, force: true, holdLive: true)
        #expect(try lastWatched(ids[0], in: container) == nil)
        #expect(try lastWatched(ids[1], in: container) == nil)

        // Closing the player on the third channel stamps all three.
        await writer.record(ref: .live(ids[2]), progress: 5, duration: 0, force: true)
        let first = try #require(try lastWatched(ids[0], in: container))
        let second = try #require(try lastWatched(ids[1], in: container))
        let third = try #require(try lastWatched(ids[2], in: container))
        #expect(first <= second)
        #expect(second <= third)
    }

    @Test func `an unheld live write saves at once`() async throws {
        let (container, ids) = try makeChannels(1)
        let writer = WatchProgressWriter(container: container)

        await writer.record(ref: .live(ids[0]), progress: 5, duration: 0, force: true)

        #expect(try lastWatched(ids[0], in: container) != nil)
    }
}

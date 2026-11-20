//
//  EPGRefreshTests.swift
//  LumeTests
//
//  A guide refresh replaces the stored guide without ever emptying it: readers
//  keep the old programmes until the new ones are in. On a real store file,
//  because the in-memory store evaluates the lookup predicate and the batch
//  delete in Swift.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct EPGRefreshTests {
    private static let day = Date(timeIntervalSince1970: 1_780_000_000)

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date) + " +0000"
    }

    /// One hour-long programme per `(channel, hour offset, title)`.
    private static func xmltv(_ programmes: [(channel: String, hour: Int, title: String)]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv>\n"
        for programme in programmes {
            let start = day.addingTimeInterval(Double(programme.hour) * 3600)
            xml += "<programme start=\"\(stamp(start))\" stop=\"\(stamp(start.addingTimeInterval(3600)))\""
            xml += " channel=\"\(programme.channel)\"><title>\(programme.title)</title></programme>\n"
        }
        return xml + "</tv>\n"
    }

    private static func makeGuideFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xml")
    }

    private static func titles(in container: ModelContainer, channel: String) throws -> [String] {
        let descriptor = FetchDescriptor<EPGListing>(
            predicate: #Predicate { $0.channelId == channel },
            sortBy: [SortDescriptor(\.start)]
        )
        return try ModelContext(container).fetch(descriptor).map(\.title)
    }

    @Test func `refresh replaces the schedule and drops programmes that left it`() async throws {
        let guide = Self.makeGuideFile()
        defer { try? FileManager.default.removeItem(at: guide) }

        try await OnDiskCatalogStore.withContext { context in
            let container = context.container
            context.insert(LiveStream(id: "live-1", streamId: 1, name: "News", epgChannelId: "news.1"))
            context.insert(LiveStream(id: "live-2", streamId: 2, name: "Film", epgChannelId: "film.1"))
            context.insert(EPGSource(name: "Guide", url: guide.absoluteString))
            try context.save()

            try Data(Self.xmltv([
                ("news.1", 0, "Morning News"), ("news.1", 1, "Weather"), ("film.1", 0, "Old Film")
            ]).utf8).write(to: guide)
            #expect(await EPGSyncManager(modelContainer: container).syncAllSources())

            // Same slot retitled, one programme gone, one added, and a channel
            // the source no longer carries.
            try Data(Self.xmltv([
                ("news.1", 0, "Breaking News"), ("news.1", 2, "Sport")
            ]).utf8).write(to: guide)
            #expect(await EPGSyncManager(modelContainer: container).syncAllSources())

            #expect(try Self.titles(in: container, channel: "news.1") == ["Breaking News", "Sport"])
            #expect(try Self.titles(in: container, channel: "film.1").isEmpty)
        }
    }

    @Test func `a source that fails to download keeps its guide`() async throws {
        let first = Self.makeGuideFile()
        let second = Self.makeGuideFile()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        try await OnDiskCatalogStore.withContext { context in
            let container = context.container
            context.insert(LiveStream(id: "live-1", streamId: 1, name: "News", epgChannelId: "news.1"))
            context.insert(LiveStream(id: "live-2", streamId: 2, name: "Film", epgChannelId: "film.1"))
            // Sources are walked oldest-first.
            let older = EPGSource(name: "First", url: first.absoluteString)
            older.addedAt = Date(timeIntervalSince1970: 1)
            let newer = EPGSource(name: "Second", url: second.absoluteString)
            newer.addedAt = Date(timeIntervalSince1970: 2)
            context.insert(older)
            context.insert(newer)
            try context.save()

            try Data(Self.xmltv([("news.1", 0, "Morning News"), ("news.1", 1, "Weather")]).utf8).write(to: first)
            try Data(Self.xmltv([("film.1", 0, "Old Film")]).utf8).write(to: second)
            #expect(await EPGSyncManager(modelContainer: container).syncAllSources())

            try Data(Self.xmltv([("news.1", 0, "Breaking News")]).utf8).write(to: first)
            try FileManager.default.removeItem(at: second)
            #expect(await EPGSyncManager(modelContainer: container).syncAllSources())

            #expect(try Self.titles(in: container, channel: "news.1") == ["Breaking News"])
            #expect(try Self.titles(in: container, channel: "film.1") == ["Old Film"])
        }
    }

    /// The reported bug: a list opened while a refresh ran saw the handful of
    /// channels ingested so far. Refreshing an unchanged guide must never show a
    /// reader fewer listings than it holds.
    @Test func `the guide stays complete while a refresh runs`() async throws {
        let guide = Self.makeGuideFile()
        defer { try? FileManager.default.removeItem(at: guide) }

        let channels = 60
        let hours = 400
        var programmes: [(channel: String, hour: Int, title: String)] = []
        for channel in 0 ..< channels {
            for hour in 0 ..< hours {
                programmes.append(("ch.\(channel)", hour, "Show \(hour)"))
            }
        }
        try Data(Self.xmltv(programmes).utf8).write(to: guide)

        try await OnDiskCatalogStore.withContext { context in
            let container = context.container
            for channel in 0 ..< channels {
                context.insert(LiveStream(
                    id: "live-\(channel)", streamId: channel, name: "Channel \(channel)", epgChannelId: "ch.\(channel)"
                ))
            }
            context.insert(EPGSource(name: "Guide", url: guide.absoluteString))
            try context.save()

            #expect(await EPGSyncManager(modelContainer: container).syncAllSources())
            let total = channels * hours
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<EPGListing>()) == total)

            let reader = Task.detached {
                var lowest = Int.max
                while !Task.isCancelled {
                    if let count = try? ModelContext(container).fetchCount(FetchDescriptor<EPGListing>()) {
                        lowest = min(lowest, count)
                    }
                    await Task.yield()
                }
                return lowest
            }
            #expect(await EPGSyncManager(modelContainer: container).syncAllSources())
            reader.cancel()
            let lowest = await reader.value

            #expect(lowest == total)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<EPGListing>()) == total)
        }
    }
}

//
//  PerfSupport.swift
//  LumePerformanceTests
//
//  Shared scaffolding for the benchmarks: an on-disk store factory and the
//  fixture generators.
//
//  Two deliberate choices here, both learned the hard way:
//
//  * **On-disk stores, not in-memory.** An in-memory `ModelContainer` skips
//    SQLite entirely, so it understates import cost by an order of magnitude and
//    hides SQL-generation behaviour outright. Import is the phase users wait on,
//    so it has to be measured against a real store file.
//  * **Generators, not checked-in fixtures.** A 600k-entry playlist is ~60 MB;
//    the repo carries the ~60-line generator instead, exactly as `ExampleData`
//    stays out of git. Generated content is deterministic (a fixed-seed LCG), so
//    a benchmark's input never changes underneath its baseline.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

// MARK: - Deterministic pseudo-randomness

/// A fixed-seed linear congruential generator. `SystemRandomNumberGenerator`
/// would make every run's fixture different, which is indistinguishable from a
/// performance regression when comparing against a baseline.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64 = 0x5EED_1234_ABCD_0001) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

// MARK: - Store factory

enum PerfStore {
    /// The catalog schema, matching `LumeApp.makeModelContainers`.
    static var catalogSchema: Schema {
        Schema([
            Playlist.self,
            Lume.Category.self,
            LiveStream.self,
            Movie.self,
            Series.self,
            Episode.self,
            CastMember.self,
            EPGListing.self,
            EPGSource.self
        ])
    }

    /// A fresh on-disk container in a unique temp directory.
    ///
    /// `cloudKitDatabase: .none` is mandatory — the catalog's
    /// `@Attribute(.unique)` models crash container load when CloudKit mirroring
    /// is left at `.automatic` on an entitled host.
    static func makeOnDiskContainer() throws -> (container: ModelContainer, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumePerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(
            schema: catalogSchema,
            url: directory.appendingPathComponent("perf.store"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: catalogSchema, configurations: configuration)
        return (container, directory)
    }

    static func destroy(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Fixture generators

enum PerfFixtures {
    /// Scratch space for generated fixtures, cleaned up by the test that made it.
    static func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumeFixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes an extended-m3u playlist with `entryCount` entries, mixing live
    /// channels, movies and episode-shaped names in roughly the proportions a
    /// provider export has — so `M3UClassifier` does representative work.
    @discardableResult
    static func writeM3U(entryCount: Int, to directory: URL) throws -> URL {
        var generator = SeededGenerator()
        let url = directory.appendingPathComponent("playlist.m3u")
        var text = "#EXTM3U url-tvg=\"https://example.invalid/guide.xml.gz\"\n"
        text.reserveCapacity(entryCount * 180)

        for index in 0 ..< entryCount {
            let bucket = Int.random(in: 0 ..< 100, using: &generator)
            let group = "Group \(index % 400)"
            if bucket < 45 {
                text += "#EXTINF:-1 tvg-id=\"ch\(index)\" tvg-name=\"Channel \(index)\" "
                text += "tvg-logo=\"https://example.invalid/logo/\(index).png\" group-title=\"\(group)\","
                text += "Channel \(index) HD\n"
                text += "https://example.invalid/live/user/pass/\(index).ts\n"
            } else if bucket < 80 {
                text += "#EXTINF:-1 tvg-id=\"\" tvg-logo=\"https://example.invalid/poster/\(index).jpg\" "
                text += "group-title=\"VOD \(group)\",Movie Title \(index) (20\(10 + index % 15))\n"
                text += "https://example.invalid/movie/user/pass/\(index).mkv\n"
            } else {
                let season = 1 + index % 6
                let episode = 1 + index % 24
                text += "#EXTINF:-1 group-title=\"Series \(group)\","
                text += "Show \(index % 900) S\(String(format: "%02d", season))E\(String(format: "%02d", episode))\n"
                text += "https://example.invalid/series/user/pass/\(index).mp4\n"
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes an XMLTV guide with `channelCount` channels × `programmesPerChannel`
    /// programmes. Timestamps use the `+0000` offset form, which is the shape
    /// `XMLTVDate` has to parse fastest.
    @discardableResult
    static func writeXMLTV(
        channelCount: Int,
        programmesPerChannel: Int,
        to directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent("guide.xml")
        var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv>\n"
        text.reserveCapacity(channelCount * programmesPerChannel * 220)

        for channel in 0 ..< channelCount {
            text += "<channel id=\"ch\(channel)\"><display-name>Channel \(channel)</display-name></channel>\n"
        }

        // Fixed epoch (not `Date()`) so the generated guide is byte-identical run
        // to run — a moving window would change parse and query costs.
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"

        for channel in 0 ..< channelCount {
            for slot in 0 ..< programmesPerChannel {
                let start = epoch.addingTimeInterval(Double(slot) * 1800)
                let end = start.addingTimeInterval(1800)
                let startStamp = formatter.string(from: start)
                let endStamp = formatter.string(from: end)
                text += "<programme start=\"\(startStamp) +0000\" stop=\"\(endStamp) +0000\" channel=\"ch\(channel)\">"
                text += "<title>Programme \(channel)-\(slot)</title>"
                text += "<desc>A synthetic description for programme \(slot) on channel \(channel).</desc>"
                text += "</programme>\n"
            }
        }
        text += "</tv>\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// An Xtream `get_vod_streams` response body with `count` movies, as `Data`
    /// ready for `JSONDecoder`. Fields mirror what panels actually send,
    /// including the string/number ambiguity the DTOs have to absorb.
    static func xtreamVODStreamsJSON(count: Int) throws -> Data {
        var generator = SeededGenerator()
        var items: [String] = []
        items.reserveCapacity(count)
        for index in 0 ..< count {
            // Half the panels send numbers as strings; alternate so the decoder's
            // lenient paths are exercised too.
            let rating = index.isMultiple(of: 2) ? "\"7.\(index % 10)\"" : "7.\(index % 10)"
            let added = 1_700_000_000 + index
            items.append("""
            {"num":\(index),"name":"Movie \(index)","stream_type":"movie",\
            "stream_id":\(100_000 + index),"stream_icon":"https://example.invalid/p/\(index).jpg",\
            "rating":\(rating),"rating_5based":\(Int.random(in: 0 ... 5, using: &generator)),\
            "added":"\(added)","category_id":"\(index % 300)","container_extension":"mkv",\
            "custom_sid":null,"direct_source":""}
            """)
        }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }
}

// MARK: - Assertions

extension XCTestCase {
    /// Fails when a generated fixture is unexpectedly small — a silently broken
    /// generator would otherwise look like a spectacular speed-up.
    func assertFixtureIsSubstantial(_ url: URL, minimumBytes: Int, file: StaticString = #filePath, line: UInt = #line) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        XCTAssertGreaterThan(
            size, minimumBytes,
            "fixture at \(url.lastPathComponent) is only \(size) bytes — the generator is probably broken",
            file: file, line: line
        )
    }
}

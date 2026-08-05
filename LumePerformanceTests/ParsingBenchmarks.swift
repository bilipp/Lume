//
//  ParsingBenchmarks.swift
//  LumePerformanceTests
//
//  Tier A: pure-CPU benchmarks over the three hot parse paths — the m3u playlist
//  parser, the XMLTV SAX parser, and Xtream DTO decoding. No network, no store,
//  no UI, so the numbers are stable enough to compare against a baseline on the
//  same machine.
//
//  These are the benchmarks that would have caught the `XMLTVDate` regression
//  (a `DateFormatter` per programme, 44.8% of a post-sync freeze) the day it
//  landed rather than after a user complained.
//
//  Sizes are a compromise: large enough that per-entry cost dominates fixture
//  generation, small enough that the suite finishes in a couple of minutes.
//  Bump `entryCount` locally when hunting a specific regression.
//

import Foundation
@testable import Lume
import XCTest

final class ParsingBenchmarks: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = try PerfFixtures.makeScratchDirectory()
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
        try super.tearDownWithError()
    }

    // MARK: - m3u

    /// Streaming parse of a 120k-entry playlist. Measures wall clock and peak
    /// memory together: the parser's contract is *flat* memory regardless of
    /// playlist size, so a regression that buffers the file would show up as a
    /// memory failure even if it parsed faster.
    func testM3UParse120kEntries() throws {
        let fixture = try PerfFixtures.writeM3U(entryCount: 120_000, to: scratch)
        assertFixtureIsSubstantial(fixture, minimumBytes: 5_000_000)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            var count = 0
            var urlBytes = 0
            do {
                count = try M3UParser.parse(fileURL: fixture, batchSize: 2000) { batch in
                    // Touch every entry so the optimizer can't discard the parse.
                    for entry in batch {
                        urlBytes += entry.url.utf8.count
                    }
                }
            } catch {
                XCTFail("m3u parse threw: \(error)")
            }
            XCTAssertEqual(count, 120_000)
            XCTAssertGreaterThan(urlBytes, 0)
        }
    }

    /// `#EXTINF` attribute scanning in isolation. It runs once per playlist line,
    /// so a constant-factor regression here multiplies by hundreds of thousands.
    func testM3UExtInfAttributeScan() {
        let line = "#EXTINF:-1 tvg-id=\"ch4711\" tvg-name=\"Channel 4711\" "
            + "tvg-logo=\"https://example.invalid/logo/4711.png\" "
            + "group-title=\"Sports, News & More\" type=\"video\",Channel 4711 HD, Extra"

        // Assertion outside the loop: per-iteration XCTAsserts would dominate.
        measure(metrics: [XCTClockMetric()]) {
            var matches = 0
            for _ in 0 ..< 20000 where M3UParser.parseExtInf(line).tvgId == "ch4711" {
                matches += 1
            }
            XCTAssertEqual(matches, 20000)
        }
    }

    /// Classification is the other per-entry cost of an m3u import — it decides
    /// live vs movie vs episode for every single line.
    func testM3UClassification() {
        let names = [
            "Channel 12 HD",
            "Movie Title 2019 (2019)",
            "Show Name S03E11",
            "Some Show 1x04 Pilot"
        ]
        let entries = (0 ..< 4000).map { index in
            M3UEntry(
                name: names[index % names.count],
                url: "https://example.invalid/stream/\(index).ts",
                tvgId: index.isMultiple(of: 2) ? "ch\(index)" : nil,
                logo: nil,
                group: "Group \(index % 100)",
                type: nil
            )
        }

        measure(metrics: [XCTClockMetric()]) {
            for entry in entries {
                _ = M3UClassifier.classify(entry)
            }
        }
    }

    // MARK: - XMLTV

    /// Streaming SAX parse of a ~120k-programme guide (400 channels × 300 slots).
    /// This is the phase that froze the app for ~9s after a sync.
    func testXMLTVParse120kProgrammes() throws {
        let fixture = try PerfFixtures.writeXMLTV(
            channelCount: 400, programmesPerChannel: 300, to: scratch
        )
        assertFixtureIsSubstantial(fixture, minimumBytes: 10_000_000)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            var total = 0
            _ = XMLTVParser.parse(fileURL: fixture, batchSize: 2000) { batch in
                total += batch.count
            }
            XCTAssertEqual(total, 120_000)
        }
    }

    /// XMLTV timestamp parsing on its own. Called twice per programme, so it is
    /// the single most-executed function in a guide refresh — and was once 45%
    /// of it (a `DateFormatter` per call, before the hand-rolled fast path).
    ///
    /// Only canonical `YYYYMMDDHHMMSS ±HHMM` stamps here: that is the shape the
    /// fast path serves, and >99% of real guide data. The assertion is outside
    /// the loop on purpose — 500k `XCTAssert` calls cost far more than the code
    /// being measured and would swamp the number.
    func testXMLTVDateFastPathParsing() {
        let stamps = [
            "20260730120000 +0000",
            "20260730123000 +0200",
            "20260730133000 -0500"
        ]

        measure(metrics: [XCTClockMetric()]) {
            var checksum = 0.0
            for index in 0 ..< 100_000 {
                checksum += XMLTVDate.parse(stamps[index % stamps.count])?.timeIntervalSince1970 ?? 0
            }
            XCTAssertGreaterThan(checksum, 0, "every canonical stamp should parse")
        }
    }

    /// The fallback path: a stamp with no UTC offset. `XMLTVDate` rejects it in
    /// the fast path and `DateFormatter` (`yyyyMMddHHmmss Z`) can't parse it
    /// either, so the result is nil — but the ICU attempt still costs, and a
    /// provider that omits offsets pays it twice per programme.
    ///
    /// Fewer iterations because this path is orders of magnitude slower. If this
    /// number ever matters in the field, the fix is to widen `XMLTVDate`, not to
    /// speed up ICU.
    func testXMLTVDateFallbackParsing() {
        measure(metrics: [XCTClockMetric()]) {
            var nilCount = 0
            for index in 0 ..< 2000
                where XMLTVDate.parse("2026073013\(String(format: "%04d", index % 6000))") == nil
            {
                nilCount += 1
            }
            XCTAssertEqual(nilCount, 2000, "offset-less stamps are expected to fail to parse")
        }
    }

    // MARK: - Xtream DTO decoding

    /// Decoding a 50k-movie `get_vod_streams` payload. Xtream syncs decode the
    /// whole catalog in one shot, so this is on the critical path of every sync.
    func testXtreamVODStreamDecoding() throws {
        let payload = try PerfFixtures.xtreamVODStreamsJSON(count: 50000)
        XCTAssertGreaterThan(payload.count, 5_000_000)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            do {
                let decoded = try JSONDecoder().decode(XtreamList<XtreamVODStream>.self, from: payload)
                XCTAssertEqual(decoded.items.count, 50000)
            } catch {
                XCTFail("Xtream VOD decode threw: \(error)")
            }
        }
    }
}

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

    /// Writes a playlist with the measured provider's shape: ~3% live on bare
    /// extension-less URLs, ~11% `/movie/….mkv`, ~86% `/series/….mkv` episodes
    /// clustered into `showCount` shows with the real long-tailed episode
    /// distribution, and the superscript decoration real names carry.
    ///
    /// Deliberately separate from `writeM3U`: that generator's 45/35/20 mix is
    /// the accepted baseline input of `testM3UParse120kEntries`, so re-shaping
    /// it in place would silently re-baseline that benchmark instead of adding
    /// a second one.
    ///
    /// The long-tailed draw averages ~37 episodes per show, so pass a
    /// `showCount` near `entryCount / 43` for every show to be used exactly
    /// once; a larger one leaves the surplus shows unemitted rather than
    /// shortening the blocks.
    @discardableResult
    static func writeM3UProviderShape(entryCount: Int, showCount: Int, to directory: URL) throws -> URL {
        var generator = SeededGenerator()
        let url = directory.appendingPathComponent("provider.m3u")
        let writer = try M3UFixtureWriter(fileURL: url)
        defer { writer.close() }

        let liveCount = entryCount * providerLiveShare / 100
        let movieCount = entryCount * providerMovieShare / 100
        writeProviderLiveEntries(count: liveCount, to: writer, using: &generator)
        writeProviderVODEntries(
            movieCount: movieCount,
            episodeCount: max(0, entryCount - liveCount - movieCount),
            showCount: showCount,
            to: writer,
            using: &generator
        )
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

    // MARK: Xtream JSON

    // Row sizes below are the ones a real 282,288-row panel sends:
    // `get_vod_streams` 367 B/row over 178,007 rows, `get_live_streams`
    // 356 B/row over 56,713, `get_series` 1033 B/row over 47,568. A generator
    // that emits a minimal subset of the keys understates decode by ~3x and
    // makes a sync benchmark measure something the app never does.

    static func pick<Element>(_ values: [Element], using generator: inout SeededGenerator) -> Element {
        values[Int.random(in: 0 ..< values.count, using: &generator)]
    }

    /// A TMDB-style image token. Its length is most of why a real `stream_icon`
    /// is 76 bytes and a naive fixture's is 30.
    private static func imageToken(length: Int = 27, using generator: inout SeededGenerator) -> String {
        var token = ""
        token.reserveCapacity(length)
        for _ in 0 ..< length {
            token.append(pick(XtreamVocabulary.tokenAlphabet, using: &generator))
        }
        return token
    }

    private static func posterURL(using generator: inout SeededGenerator) -> String {
        let roll = Int.random(in: 0 ..< 100, using: &generator)
        if roll == 0 { return "" }
        let size = roll < 12 ? "w154" : "w600_and_h900_bestv2"
        return "https://image.tmdb.org/t/p/\(size)/\(imageToken(using: &generator)).jpg"
    }

    private static func channelLogoURL(using generator: inout SeededGenerator) -> String {
        if Int.random(in: 0 ..< 100, using: &generator) < 3 { return "" }
        return "https://upload.wikimedia.org/wikipedia/commons/4/42/\(imageToken(using: &generator)).png"
    }

    /// `backdrop_path` element counts as the provider sends them — mean 2.8.
    private static let backdropCounts = [0, 1, 2, 2, 3, 3, 3, 4, 4, 5, 6, 7]

    /// The comma-joined, already-quoted elements of a `backdrop_path` array.
    private static func backdropURLs(using generator: inout SeededGenerator) -> String {
        let count = pick(backdropCounts, using: &generator)
        var urls: [String] = []
        urls.reserveCapacity(count)
        for _ in 0 ..< count {
            let size = Int.random(in: 0 ..< 10, using: &generator) < 4 ? "original" : "w1280"
            urls.append("\"https://image.tmdb.org/t/p/\(size)/\(imageToken(using: &generator)).jpg\"")
        }
        return urls.joined(separator: ",")
    }

    private static func title(index: Int, using generator: inout SeededGenerator) -> String {
        let adjective = pick(XtreamVocabulary.adjectives, using: &generator)
        let noun = pick(XtreamVocabulary.nouns, using: &generator)
        var name = "\(adjective) \(noun)"
        if index.isMultiple(of: 3) {
            name = "\(pick(XtreamVocabulary.adjectives, using: &generator)) \(name)"
        }
        return "\(name) (\(1970 + index % 56))"
    }

    private static func personName(using generator: inout SeededGenerator) -> String {
        let first = pick(XtreamVocabulary.firstNames, using: &generator)
        let last = pick(XtreamVocabulary.lastNames, using: &generator)
        return "\(first) \(last)"
    }

    private static let castSizes = [0, 3, 5, 6, 7]

    private static func castList(using generator: inout SeededGenerator) -> String {
        let count = pick(castSizes, using: &generator)
        var names: [String] = []
        names.reserveCapacity(count)
        for _ in 0 ..< count {
            names.append(personName(using: &generator))
        }
        return names.joined(separator: ", ")
    }

    /// Words drawn until the result is at least `minimumLength` characters. Plot
    /// text is the bulk of a `get_series` row and the reason it is 3x a VOD row.
    private static func phrase(
        minimumLength: Int,
        from words: [String],
        using generator: inout SeededGenerator
    ) -> String {
        var parts: [String] = []
        var length = 0
        while length < minimumLength {
            let word = pick(words, using: &generator)
            parts.append(word)
            length += word.count + 1
        }
        return parts.joined(separator: " ")
    }

    /// An Xtream `get_vod_streams` response body with `count` movies, as `Data`
    /// ready for `JSONDecoder`.
    ///
    /// The field mix is the provider's, not the DTO's: `rating` arrives as a
    /// String, `rating_5based` as a JSON number, `is_adult` as a String, and
    /// `category_ids` / `custom_sid` / `direct_source` are keys
    /// `XtreamVODStream` never reads but `JSONDecoder` still parses.
    static func xtreamVODStreamsJSON(count: Int) throws -> Data {
        var generator = SeededGenerator()
        var json = "["
        json.reserveCapacity(count * 380 + 2)
        for index in 0 ..< count {
            if index > 0 { json += "," }
            let categoryId = 2000 + index % 441
            let rating = pick(XtreamVocabulary.vodRatings, using: &generator)
            let rating5 = pick(XtreamVocabulary.vodRatings5Based, using: &generator)
            // One provider is self-consistent, panel forks are not — alternate a
            // quarter of the rows so both branches of `lenientDouble` and
            // `lenientInt` stay on the measured path.
            let flipped = index % 4 == 3
            let ratingField = flipped ? rating : "\"\(rating)\""
            let rating5Field = flipped ? "\"\(rating5)\"" : rating5
            let isAdultField = flipped ? "0" : "\"0\""
            let container = pick(XtreamVocabulary.containerExtensions, using: &generator)
            json += #"{"num":\#(index + 1),"stream_type":"movie","#
            json += #""name":"\#(title(index: index, using: &generator))","#
            json += #""stream_id":\#(1_500_000 + index),"stream_icon":"\#(posterURL(using: &generator))","#
            json += #""rating":\#(ratingField),"rating_5based":\#(rating5Field),"#
            json += #""added":"\#(1_759_931_040 + index)","is_adult":\#(isAdultField),"#
            json += #""category_id":"\#(categoryId)","category_ids":[\#(categoryId)],"#
            json += #""container_extension":"\#(container)","custom_sid":null,"direct_source":""}"#
        }
        json += "]"
        return Data(json.utf8)
    }

    /// An Xtream `get_series` response body with `count` series.
    ///
    /// Series is the endpoint where `rating` *and* `rating_5based` are Strings
    /// and `backdrop_path` is an **array** of URLs rather than a scalar. A
    /// fixture that sends a string there decodes just as happily and still hides
    /// ~220 B/row of parsing, which is why the array is generated in full.
    static func xtreamSeriesJSON(count: Int) throws -> Data {
        var generator = SeededGenerator()
        var json = "["
        json.reserveCapacity(count * 1060 + 2)
        for index in 0 ..< count {
            if index > 0 { json += "," }
            let categoryId = 400 + index % 374
            let plot = phrase(minimumLength: 285, from: XtreamVocabulary.plotWords, using: &generator)
            let trailer = index.isMultiple(of: 2) ? imageToken(length: 11, using: &generator) : ""
            json += #"{"num":\#(index + 1),"name":"\#(title(index: index, using: &generator))","#
            json += #""series_id":\#(13000 + index),"cover":"\#(posterURL(using: &generator))","#
            json += #""plot":"\#(plot)","cast":"\#(castList(using: &generator))","#
            json += #""director":"\#(personName(using: &generator))","#
            json += #""genre":"\#(pick(XtreamVocabulary.genres, using: &generator))","#
            json += #""releaseDate":"\#(1970 + index % 56)-0\#(1 + index % 9)-1\#(index % 9)","#
            json += #""last_modified":"\#(1_776_621_142 + index)","#
            json += #""rating":"\#(pick(XtreamVocabulary.seriesRatings, using: &generator))","#
            json += #""rating_5based":"\#(pick(XtreamVocabulary.seriesRatings5Based, using: &generator))","#
            json += #""backdrop_path":[\#(backdropURLs(using: &generator))],"#
            json += #""youtube_trailer":"\#(trailer)","#
            json += #""episode_run_time":"\#(pick(XtreamVocabulary.episodeRunTimes, using: &generator))","#
            json += #""category_id":"\#(categoryId)","category_ids":[\#(categoryId)]}"#
        }
        json += "]"
        return Data(json.utf8)
    }

    /// An Xtream `get_live_streams` response body with `count` channels.
    ///
    /// Live is the endpoint that sends true JSON numbers — `num`, `stream_id`,
    /// `tv_archive`, `tv_archive_duration` and `is_adult` all arrive unquoted,
    /// the other half of `lenientInt`'s work — and where `epg_channel_id` is
    /// usually the empty string rather than absent.
    static func xtreamLiveStreamsJSON(count: Int) throws -> Data {
        var generator = SeededGenerator()
        var json = "["
        json.reserveCapacity(count * 370 + 2)
        for index in 0 ..< count {
            if index > 0 { json += "," }
            let categoryId = 2000 + index % 910
            let archived = index % 56 == 0
            let suffix = pick(XtreamVocabulary.liveSuffixes, using: &generator)
            let name = title(index: index, using: &generator) + suffix
            let epgId = index % 7 == 0
                ? "\(pick(XtreamVocabulary.nouns, using: &generator)).\(index % 90).tv"
                : ""
            json += #"{"num":\#(index + 1),"stream_type":"live","name":"\#(name)","#
            json += #""stream_id":\#(1_600_000 + index),"stream_icon":"\#(channelLogoURL(using: &generator))","#
            json += #""epg_channel_id":"\#(epgId)","#
            json += #""category_id":"\#(categoryId)","category_ids":[\#(categoryId)],"#
            json += #""added":"\#(1_760_346_276 + index)","tv_archive_duration":\#(archived ? 3 : 0),"#
            json += #""is_adult":0,"tv_archive":\#(archived ? 1 : 0),"#
            json += #""custom_sid":null,"direct_source":""}"#
        }
        json += "]"
        return Data(json.utf8)
    }
}

// MARK: - Xtream fixture vocabulary

/// Deterministic word pools for the fixture generators — the Xtream ones, and
/// the title halves the provider-shaped m3u generator shares with them.
///
/// Real catalog rows carry multi-byte characters in titles and plots — curly
/// apostrophes, em dashes, superscript channel tags — and that UTF-8 is a real
/// share of what a 135 MB sync spends in `JSONDecoder`, so the pools carry them
/// too rather than staying ASCII.
enum XtreamVocabulary {
    static let adjectives = [
        "Shadow", "Crimson", "Midnight", "Eternal", "Silent", "Broken", "Northern", "Last",
        "Golden", "Winter", "Distant", "Hollow", "Rising", "Iron", "Velvet", "Quiet",
        "Forgotten", "Wild", "Second", "Bright", "Frozen", "Sacred", "Hidden", "Restless"
    ]

    static let nouns = [
        "Harbour", "Kingdom", "Machine", "Promise", "Circuit", "Garden", "Verdict", "Orbit",
        "Signal", "Country", "Mirror", "Lantern", "Compass", "Season", "Threshold", "Anthem",
        "Passage", "Reckoning", "Cartel", "Frontier"
    ]

    static let plotWords = [
        "A", "the", "story", "follows", "an", "unlikely", "crew", "across", "a", "fractured",
        "city", "where", "every", "choice", "costs", "more", "than", "it", "should", "and",
        "nobody", "leaves", "unchanged", "after", "the", "long", "winter", "ends", "world’s",
        "don’t", "—", "quietly", "between", "two", "families", "bound", "by", "an", "old", "debt"
    ]

    static let firstNames = [
        "Eugenio", "Enrique", "Raphael", "Camila", "Chord", "Fernando", "Jessica", "Vanessa",
        "Marguerite", "Aleksander", "Yuki", "Priya", "Tomasz", "Ingrid"
    ]

    static let lastNames = [
        "Derbez", "Arrizon", "Alejandro", "Perez", "Overstreet", "Carsa", "Collins", "Bauche",
        "Lindqvist", "Nakamura", "Okonkwo", "Rossi", "Kowalski", "Alvarez"
    ]

    static let genres = [
        "Comedy / Drama", "Sci-Fi & Fantasy / Action & Adventure", "Kids / Family / Comedy",
        "Documentary", "Crime / Mystery", "Action / Thriller", "Animation"
    ]

    /// Weighted the way the measured catalog is: mkv dominates, mp4 next.
    static let containerExtensions = ["mkv", "mkv", "mkv", "mp4", "mp4", "avi"]

    /// VOD `rating`. Mostly one or two characters — the measured mean is 3.0, so
    /// a fixture that always emits "6.244" is already too wide.
    static let vodRatings = ["0", "6", "7", "5", "8", "6.5", "6.2", "7.1", "6.244", "7.565"]

    /// VOD `rating_5based`, quantised to whole steps the way the panel emits it.
    static let vodRatings5Based = ["3.0", "4.0", "0.0", "2.0", "5.0", "1.0"]

    /// Series ratings are Strings on both keys, and on a different scale.
    static let seriesRatings = ["8", "7", "6", "0", "9", "5", "10"]
    static let seriesRatings5Based = ["1.6", "1.4", "1.2", "0", "1.8", "1", "2.4"]

    static let episodeRunTimes = ["0", "0", "0", "45", "60", "24", "50", "30"]

    static let tokenAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// Superscript decorations on live channel names — three UTF-8 bytes each,
    /// and the provider's live list is full of them.
    static let liveSuffixes = ["", "", "", "", " ᴴᴰ"]
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

    /// Fails when a generated Xtream fixture drifts away from the row size the
    /// real provider sends. A generator emitting 110 B/row where the panel emits
    /// 367 makes every decode benchmark look three times cheaper than the sync
    /// phase it stands in for.
    func assertBytesPerRow(
        _ payload: Data,
        rows: Int,
        expected: Int,
        tolerance: Double = 0.12,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = Double(payload.count) / Double(rows)
        let band = Double(expected) * (1 - tolerance) ... Double(expected) * (1 + tolerance)
        XCTAssertTrue(
            band.contains(actual),
            "fixture is \(Int(actual)) B/row; the provider sends \(expected) B/row (±\(Int(tolerance * 100))%)",
            file: file, line: line
        )
    }
}

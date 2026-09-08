//
//  PerfM3UProviderFixture.swift
//  LumePerformanceTests
//
//  The provider-shaped m3u generator behind
//  `PerfFixtures.writeM3UProviderShape`, kept out of `PerfSupport.swift`
//  because that file is close to SwiftLint's 600-line limit and the hook runs
//  `--strict`.
//
//  Everything here is modelled on one measured provider export: 520 MB,
//  1,719,199 entries — 1,484,110 `/series/` episodes across ~47.4k shows,
//  178,231 `/movie/` rows, 56,858 bare extensionless live URLs, 1,544 distinct
//  group titles. The synthetic mix in `writeM3U` is nothing like that, which is
//  why classification benchmarked against it could not see the regex work.
//

import Foundation

// MARK: - Streaming writer

/// Appends playlist entries to a file handle through a fixed-size buffer.
/// The full-scale shape is half a gigabyte, so the fixture is never held as one
/// String — `reserveCapacity` at that size wants a contiguous allocation an
/// Apple TV does not have.
final class M3UFixtureWriter {
    private let handle: FileHandle
    private var buffer: String
    private(set) var entryCount = 0

    /// Flush threshold. Large enough that the write syscall is amortized over
    /// hundreds of entries, small enough that the buffer never grows the heap.
    private static let flushThreshold = 256 * 1024

    init(fileURL: URL) throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)
        buffer = "#EXTM3U url-tvg=\"https://example.invalid/xmltv.php\"\n"
        buffer.reserveCapacity(Self.flushThreshold * 2)
    }

    func emit(name: String, logo: String, group: String, url: String) {
        buffer += "#EXTINF:-1 tvg-id=\"\" tvg-name=\"\(name)\" tvg-logo=\"\(logo)\" "
        buffer += "group-title=\"\(group)\",\(name)\n"
        buffer += "\(url)\n"
        entryCount += 1
        if buffer.utf8.count >= Self.flushThreshold {
            handle.write(Data(buffer.utf8))
            buffer.removeAll(keepingCapacity: true)
        }
    }

    func close() {
        if !buffer.isEmpty {
            handle.write(Data(buffer.utf8))
            buffer.removeAll(keepingCapacity: false)
        }
        try? handle.close()
    }
}

// MARK: - Provider-shaped sections

extension PerfFixtures {
    /// Share of entries that are live channels, then movies. The remainder is
    /// episodes. Measured: 3.31% / 10.37% / 86.32%.
    static let providerLiveShare = 3
    static let providerMovieShare = 11

    /// Bare, extension-less live URLs — `https://host/<user>/<pass>/<id>`. That
    /// shape is the one `M3UClassifier` resolves by falling all the way through
    /// to its final `.live`, and it does not occur in `writeM3U` at all.
    static func writeProviderLiveEntries(
        count: Int,
        to writer: M3UFixtureWriter,
        using generator: inout SeededGenerator
    ) {
        for index in 0 ..< count {
            let name = "\(pick(M3UProviderVocabulary.countries, using: &generator)): "
                + "\(pick(XtreamVocabulary.nouns, using: &generator)) \(index % 90)"
                + pick(M3UProviderVocabulary.decorations, using: &generator)
            writer.emit(
                name: name,
                logo: "http://photo.example.invalid/stalker_portal/misc/logos/320/"
                    + "\(index % 15000).png?\(index % 90000)",
                group: "\(pick(M3UProviderVocabulary.liveGroups, using: &generator))"
                    + pick(M3UProviderVocabulary.decorations, using: &generator),
                url: "https://example.invalid/92mc7c964u/n835i3j9a6/\(1_500_000 + index)"
            )
        }
    }

    /// Movies and episodes, interleaved the way the export orders them: a show's
    /// episodes arrive contiguously, with movie groups between shows.
    ///
    /// Episodes are drawn per show from the measured long tail (median 12,
    /// p99 279, max 2,799) rather than a uniform range, so one show's block can
    /// be three orders of magnitude larger than another's — the shape that
    /// decides how large a single batch's series clustering gets.
    static func writeProviderVODEntries(
        movieCount: Int,
        episodeCount: Int,
        showCount: Int,
        to writer: M3UFixtureWriter,
        using generator: inout SeededGenerator
    ) {
        var shows: [(name: String, group: String, logo: String)] = []
        shows.reserveCapacity(max(showCount, 1))
        for index in 0 ..< max(showCount, 1) {
            shows.append(showDescriptor(index: index, using: &generator))
        }
        var seasonCursor = [Int](repeating: 1, count: shows.count)
        var episodesDone = 0
        var moviesDone = 0
        var showIndex = 0
        var streamId = 200_000

        while episodesDone < episodeCount {
            let show = shows[showIndex]
            let wanted = min(episodesForOneShow(using: &generator), episodeCount - episodesDone)
            var season = seasonCursor[showIndex]
            var number = 1
            for _ in 0 ..< wanted {
                streamId += 1
                writer.emit(
                    name: "\(show.name) \(seasonEpisodeToken(season, number))",
                    logo: show.logo,
                    group: show.group,
                    url: "https://example.invalid/series/92mc7c964u/n835i3j9a6/\(streamId).mkv"
                )
                number += 1
                if number > 30 {
                    season += 1
                    number = 1
                }
            }
            seasonCursor[showIndex] = season + 1
            episodesDone += wanted
            showIndex = (showIndex + 1) % shows.count

            let due = movieCount * episodesDone / max(episodeCount, 1)
            while moviesDone < due {
                writeProviderMovie(index: moviesDone, to: writer, using: &generator)
                moviesDone += 1
            }
        }
        while moviesDone < movieCount {
            writeProviderMovie(index: moviesDone, to: writer, using: &generator)
            moviesDone += 1
        }
    }

    private static func writeProviderMovie(
        index: Int,
        to writer: M3UFixtureWriter,
        using generator: inout SeededGenerator
    ) {
        let name = "\(pick(M3UProviderVocabulary.countries, using: &generator)) - "
            + "\(pick(XtreamVocabulary.adjectives, using: &generator)) "
            + "\(pick(XtreamVocabulary.nouns, using: &generator)) (\(1970 + index % 56))"
        writer.emit(
            name: name,
            logo: "https://image.tmdb.org/t/p/w600_and_h900_bestv2/"
                + "\(pick(M3UProviderVocabulary.posterTokens, using: &generator))\(index % 997).jpg",
            group: "\(pick(M3UProviderVocabulary.vodGroups, using: &generator)) \(index % 60)",
            url: "https://example.invalid/movie/92mc7c964u/n835i3j9a6/\(700_000 + index).mkv"
        )
    }

    /// A show's fixed identity. Precomputed rather than re-derived per pass:
    /// drawing the name again would give the same show a different title on its
    /// second block and inflate the distinct-series count past `showCount`.
    private static func showDescriptor(
        index: Int,
        using generator: inout SeededGenerator
    ) -> (name: String, group: String, logo: String) {
        var name = "\(pick(M3UProviderVocabulary.countries, using: &generator)) - "
            + "\(pick(XtreamVocabulary.adjectives, using: &generator)) "
            + "\(pick(XtreamVocabulary.nouns, using: &generator)) (\(1990 + index % 36))"
        if index % 5 == 0 {
            name += " (\(pick(M3UProviderVocabulary.countries, using: &generator)))"
        }
        if index % 11 == 0 {
            name += pick(M3UProviderVocabulary.decorations, using: &generator)
        }
        return (
            name,
            "\(pick(M3UProviderVocabulary.seriesGroups, using: &generator)) \(index % 90)",
            "https://image.tmdb.org/t/p/w154/"
                + "\(pick(M3UProviderVocabulary.posterTokens, using: &generator))\(index % 883).jpg"
        )
    }

    /// `S01 E05` — the spaced form this provider emits, which only matches
    /// because the pattern allows `\s*` between the two halves.
    private static func seasonEpisodeToken(_ season: Int, _ episode: Int) -> String {
        let seasonText = season < 10 ? "0\(season)" : "\(season)"
        let episodeText = episode < 10 ? "0\(episode)" : "\(episode)"
        return "S\(seasonText) E\(episodeText)"
    }

    /// Episode counts per show as parts-per-thousand buckets, fitted to the
    /// measured catalog: median 12, p99 279, max 2,799.
    private static let episodeCountBuckets: [(share: Int, range: ClosedRange<Int>)] = [
        (100, 1 ... 3), (150, 4 ... 7), (250, 8 ... 12), (250, 13 ... 26),
        (150, 27 ... 60), (70, 61 ... 140), (20, 141 ... 279), (10, 280 ... 2799)
    ]

    private static func episodesForOneShow(using generator: inout SeededGenerator) -> Int {
        var roll = Int.random(in: 0 ..< 1000, using: &generator)
        for bucket in episodeCountBuckets {
            if roll < bucket.share {
                return Int.random(in: bucket.range, using: &generator)
            }
            roll -= bucket.share
        }
        return 12
    }
}

// MARK: - Vocabulary

/// Word pools for the provider-shaped generator.
///
/// The superscript decorations are not garnish: real provider names are dense
/// with them, and a name that is not plain ASCII is what makes
/// `NSRegularExpression`'s NSString bridge cost what it costs. An ASCII-only
/// fixture measures a classifier the import never runs.
enum M3UProviderVocabulary {
    static let countries = [
        "EN", "ES", "FR", "DE", "IT", "NL", "PT", "AR", "TR", "SC", "NF", "US", "UK", "CA"
    ]

    static let decorations = [
        "", "", "", "", " ᴴᴰ", " ᴿᴬᵂ", " ᵁᴴᴰ ³⁸⁴⁰ᴾ", " ⁸ᴷ", " ᵉˢ"
    ]

    static let liveGroups = [
        "4K| ᵁᴴᴰ ³⁸⁴⁰ᴾ", "8K| SPORT ON AIR", "AR| SPORTS PPV", "EN| ENTERTAINMENT",
        "DE| NACHRICHTEN", "FR| CINEMA", "IT| SKY", "ES| DEPORTES", "NL| ZIGGO",
        "PT| DESPORTO", "TR| HABER", "US| LOCALS"
    ]

    static let vodGroups = [
        "EN - NEW RELEASE", "NETFLIX HEVC", "NORDIC FILM NEW RELEASE", "FR - NOUVEAUTES",
        "DE - KINO", "IT - PRIMA VISIONE", "ES - ESTRENOS", "AR - AFLAM", "4K UHD MOVIES"
    ]

    static let seriesGroups = [
        "FRANCE ENFANTS", "EN - NETFLIX SERIES", "DE - SERIEN", "IT - SERIE TV",
        "ES - SERIES", "TR - DIZI", "AR - MOSALSALAT", "NORDIC SERIES", "US - HBO"
    ]

    /// TMDB-style poster tokens. Their length is most of why a real `tvg-logo`
    /// attribute is ~70 bytes rather than 20.
    static let posterTokens = [
        "a66w2eVNFHMgevJlw0d6f4TT", "bVJLLHO7J6OiMC2LYujbF1N6", "eSmOMXnpFucUeyUJtF0hDIUk",
        "mt4nFrjKu5JKAtxqRpEYKSky", "gPbM0MK8CP8A174rmUwGsADN", "qJ2tW6WMUDux911r6m7haRef"
    ]
}

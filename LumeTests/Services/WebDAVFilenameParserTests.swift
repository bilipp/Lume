//
//  WebDAVFilenameParserTests.swift
//  LumeTests
//
//  A WebDAV share gives Lume nothing but filenames, so this normalization is
//  the only thing standing between a NAS and a catalog of junk titles. The
//  contract it shares with the indexer: under-strip rather than mangle — a
//  missed TMDB match is acceptable, a wrong title is not.
//

import Foundation
@testable import Lume
import Testing

struct WebDAVFilenameParserTests {
    /// The reference file on the verified test share. The release tags after
    /// the token must leave an *empty* episode title, not "1080p WEB h264".
    @Test func `scene episode filename yields series season episode and no junk title`() {
        let parsed = MediaFilenameParser.parse(
            filename: "Love.is.Blind.Germany.S02E01.1080p.WEB.h264-EDITH[EZTVx.to].mkv",
            folder: "Shows"
        )

        #expect(parsed.kind == .episode(series: "Love is Blind Germany", season: 2, episode: 1, title: ""))
        #expect(parsed.name == "Love is Blind Germany S02E01")
        #expect(parsed.group == "Shows")

        // The synthesized name has to round-trip through the untouched m3u
        // classifier — that is what makes the import path reusable.
        let entry = M3UEntry(name: parsed.name, url: "http://nas/x.mkv", tvgId: nil, logo: nil, group: nil, type: nil)
        #expect(M3UClassifier.classify(entry) == .episode(series: "Love is Blind Germany", season: 2, episode: 1))
    }

    /// The filename decides movie-vs-series, so a folder named "Movies" must
    /// not stop an `SxxExx` file from importing as an episode — and the folder
    /// is still the browse category either way.
    @Test func `movie filename keeps its year and its folder category`() {
        let parsed = MediaFilenameParser.parse(
            filename: "The.Godfather.1972.1080p.BluRay.x264-GROUP.mkv",
            folder: "Movies"
        )

        #expect(parsed.kind == .movie)
        #expect(parsed.name == "The Godfather 1972")
        #expect(parsed.group == "Movies")

        let query = ContentIndexText.searchQuery(for: parsed.name)
        #expect(query.title == "The Godfather")
        #expect(query.year == 1972)
    }

    @Test func `an NxM token is recognized and its tags stripped from the episode title`() {
        let parsed = MediaFilenameParser.parse(filename: "Firefly.1x05.Safe.HDTV.x264-CTU.avi", folder: nil)

        #expect(parsed.kind == .episode(series: "Firefly", season: 1, episode: 5, title: "Safe"))
        #expect(parsed.name == "Firefly S01E05 Safe")
        #expect(parsed.group == nil)
    }

    @Test func `a clean filename is left alone`() {
        let parsed = MediaFilenameParser.parse(filename: "The Bear.mkv", folder: "Series")

        #expect(parsed.kind == .movie)
        #expect(parsed.name == "The Bear")
    }

    /// Word-boundary matching, both directions: a four-digit number that is
    /// part of the title is not a resolution, and a release tag spelled inside
    /// a real word is not a release tag.
    @Test func `title tokens are not mistaken for release tags`() {
        #expect(MediaFilenameParser.parse(filename: "Blade Runner 2049.mkv").name == "Blade Runner 2049")
        #expect(MediaFilenameParser.parse(filename: "Cobweb.mkv").name == "Cobweb")
        #expect(MediaFilenameParser.parse(filename: "X-MEN.mkv").name == "X-MEN")
    }

    @Test func `scene normalization only fires on scene-shaped names`() {
        #expect(MediaFilenameParser.sceneNormalizedName("Der Pate (1972)") == nil)
        #expect(MediaFilenameParser.sceneNormalizedName("Inception") == nil)
        #expect(MediaFilenameParser.sceneNormalizedName("The.Godfather.1972.1080p.x264-GRP") == "The Godfather 1972")
    }
}

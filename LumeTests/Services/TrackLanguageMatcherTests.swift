//
//  TrackLanguageMatcherTests.swift
//  LumeTests
//
//  Covers the engine-independent track language matcher: what a container tag
//  or a free-text track name normalizes to, and which track an ordered
//  preference list picks. The critical invariant is that "no match" stays
//  `nil` — an unmatched stream must keep the container's own selection, never
//  fall back to the first track.
//

import Foundation
@testable import Lume
import Testing

struct TrackLanguageMatcherTests {
    private typealias Track = TrackLanguageMatcher.Track

    // MARK: - Normalization

    @Test(
        arguments: [
            ("ger", "de"), ("fre", "fr"), ("chi", "zh"), ("cze", "cs"), ("dut", "nl"),
            ("gre", "el"), ("ice", "is"), ("mac", "mk"), ("may", "ms"), ("per", "fa"),
            ("rum", "ro"), ("slo", "sk"), ("tib", "bo"), ("wel", "cy"), ("arm", "hy"),
            ("baq", "eu"), ("bur", "my"), ("geo", "ka"), ("alb", "sq")
        ]
    )
    func `bibliographic ISO 639-2/B tags normalize`(raw: String, expected: String) {
        #expect(TrackLanguageMatcher.normalize(raw) == expected)
    }

    @Test(
        arguments: [("deu", "de"), ("fra", "fr"), ("eng", "en"), ("spa", "es"), ("jpn", "ja"), ("nld", "nl")]
    )
    func `terminological ISO 639-2/T tags normalize`(raw: String, expected: String) {
        #expect(TrackLanguageMatcher.normalize(raw) == expected)
    }

    @Test
    func `a three-letter code with no two-letter form stays itself`() {
        #expect(TrackLanguageMatcher.normalize("fil") == "fil")
    }

    @Test(
        arguments: [("de-DE", "de"), ("de_DE", "de"), ("de-AT", "de"), ("pt-BR", "pt"), ("zh-Hans", "zh"), ("EN-gb", "en")]
    )
    func `region and script subtags are dropped`(raw: String, expected: String) {
        #expect(TrackLanguageMatcher.normalize(raw) == expected)
    }

    @Test(
        arguments: [
            ("Deutsch", "de"), ("German", "de"), ("français", "fr"), ("español", "es"),
            ("日本語", "ja"), ("GER 5.1", "de"), ("Audio 1 - English", "en"),
            ("English AD", "en"), ("Italiano (Commentary)", "it")
        ]
    )
    func `free-text track names normalize`(raw: String, expected: String) {
        #expect(TrackLanguageMatcher.normalize(raw) == expected)
    }

    @Test(
        arguments: ["und", "mul", "mis", "zxx", "VO", "VOST", "Multi", "Original", "unknown", "", "   ", "xx", "Track 1", "5.1"]
    )
    func `placeholders and junk name no language`(raw: String) {
        #expect(TrackLanguageMatcher.normalize(raw) == nil)
    }

    // MARK: - Best match

    @Test
    func `an empty preference list changes nothing`() {
        let tracks = [Track(languageTag: "eng"), Track(languageTag: "ger")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: []) == nil)
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: ["   ", ""]) == nil)
    }

    @Test
    func `no match returns nil rather than the first track`() {
        let tracks = [Track(languageTag: "eng"), Track(languageTag: "fre"), Track(languageTag: "und", label: "Multi")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: ["ja"]) == nil)
        #expect(TrackLanguageMatcher.bestMatchIndex(in: [], preferring: ["de"]) == nil)
    }

    @Test
    func `earlier preference entries beat later ones`() {
        let tracks = [Track(languageTag: "eng"), Track(languageTag: "ger"), Track(languageTag: "ita")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: ["de", "en"]) == 1)
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: ["en", "de"]) == 0)
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: ["it", "de", "en"]) == 2)
    }

    @Test
    func `an exact bare code beats a regional variant of the same language`() {
        let variantFirst = [Track(languageTag: "de-AT"), Track(languageTag: "de")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: variantFirst, preferring: ["de"]) == 1)

        let variantOnly = [Track(languageTag: "eng"), Track(languageTag: "pt-BR")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: variantOnly, preferring: ["pt"]) == 1)
    }

    @Test
    func `within one language the first container track wins`() {
        let tracks = [Track(languageTag: "ger", label: "Deutsch Stereo"), Track(languageTag: "ger", label: "Deutsch 5.1")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: ["de"]) == 0)
    }

    @Test
    func `a container tag beats the same language found in free text`() {
        let tracks = [Track(languageTag: "und", label: "Deutsch"), Track(languageTag: "ger")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: ["de"]) == 1)
    }

    @Test
    func `commentary and audio-description tracks are de-prioritised`() {
        let commentary = [Track(languageTag: "eng", label: "English Commentary"), Track(languageTag: "eng", label: "English")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: commentary, preferring: ["en"]) == 1)

        let described = [Track(languageTag: "eng", label: "English AD"), Track(languageTag: "eng", label: "English")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: described, preferring: ["en"]) == 1)

        let german = [Track(languageTag: "ger", label: "Deutsch (Kommentar)"), Track(languageTag: "ger", label: "Deutsch")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: german, preferring: ["de"]) == 1)
    }

    @Test
    func `a commentary track still wins when it is the only match`() {
        let tracks = [Track(languageTag: "eng"), Track(languageTag: "ger", label: "Deutsch Audiokommentar")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: ["de"]) == 1)
    }

    @Test
    func `the preference beats the container's default track`() {
        // The default disposition is deliberately not an input: track 0 is what
        // the container would have played, and the preference overrules it.
        let tracks = [Track(languageTag: "eng", label: "English (Default)"), Track(languageTag: "ger")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: ["de"]) == 1)
    }

    @Test
    func `free-text-only tracks still match`() {
        let tracks = [Track(label: "Audio 1 - English"), Track(label: "Audio 2 - Deutsch 5.1")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: ["de"]) == 1)
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: ["en"]) == 0)
    }

    @Test
    func `preferences given as names or bibliographic codes work too`() {
        let tracks = [Track(languageTag: "eng"), Track(languageTag: "ger")]
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: ["ger"]) == 1)
        #expect(TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: ["German"]) == 1)
    }

    // MARK: - Foreign audio

    @Test
    func `nothing is foreign without a preference`() {
        #expect(TrackLanguageMatcher.isForeign(Track(languageTag: "eng"), comparedTo: []) == false)
    }

    @Test
    func `foreign audio is audio in no preferred language`() {
        #expect(TrackLanguageMatcher.isForeign(Track(languageTag: "eng"), comparedTo: ["de"]))
        #expect(TrackLanguageMatcher.isForeign(Track(languageTag: "de-AT"), comparedTo: ["de"]) == false)
        #expect(TrackLanguageMatcher.isForeign(Track(label: "Deutsch"), comparedTo: ["de"]) == false)
    }

    @Test
    func `an unknown language is not foreign`() {
        #expect(TrackLanguageMatcher.isForeign(Track(languageTag: "und", label: "Track 1"), comparedTo: ["de"]) == false)
    }

    // MARK: - Display names

    @Test
    func `display names resolve, and fall back to the raw code`() {
        #expect(TrackLanguageMatcher.displayName(for: "de") != "DE")
        #expect(TrackLanguageMatcher.displayName(for: "qqq") == "QQQ")
    }
}

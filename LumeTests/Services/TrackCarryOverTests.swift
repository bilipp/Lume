//
//  TrackCarryOverTests.swift
//  LumeTests
//
//  Covers the audio and subtitle picks LumeEngine and AetherEngine carry into
//  the next episode or a fresh session of the same stream: which stream
//  changes carry, how a carried audio pick reorders the preferred languages,
//  and which track of the new stream a carried subtitle lands on. The critical
//  invariant is that "no match" stays `.keep` — the new stream keeps the
//  engine's own pick rather than a track in some other language.
//

import Foundation
@testable import Lume
import Testing

struct TrackCarryOverTests {
    private typealias Track = TrackLanguageMatcher.Track
    private typealias Candidate = TrackCarryOver.Candidate

    // MARK: - Which stream changes carry

    @Test func `nothing carries into the first stream`() throws {
        #expect(try TrackCarryOver.carries(from: nil, to: media(.episode("e1"))) == false)
    }

    @Test func `the next episode carries`() throws {
        #expect(try TrackCarryOver.carries(from: media(.episode("e1")), to: media(.episode("e2"))))
    }

    @Test func `a fresh session of the same stream carries`() throws {
        let channel = try media(.live("c1"), kind: .live)
        #expect(TrackCarryOver.carries(from: channel, to: channel.resuming(at: 0)))
    }

    @Test func `the next film does not carry`() throws {
        #expect(try TrackCarryOver.carries(from: media(.movie("m1")), to: media(.movie("m2"))) == false)
    }

    @Test func `the next channel does not carry`() throws {
        let from = try media(.live("c1"), kind: .live)
        let next = try media(.live("c2"), kind: .live)
        #expect(TrackCarryOver.carries(from: from, to: next) == false)
    }

    @Test func `a film after an episode does not carry`() throws {
        #expect(try TrackCarryOver.carries(from: media(.episode("e1")), to: media(.movie("m1"))) == false)
    }

    // MARK: - Audio

    @Test func `no audio pick leaves the preferred languages alone`() {
        #expect(TrackCarryOver().audioLanguages(over: ["de", "en"]) == ["de", "en"])
    }

    @Test func `the picked audio language goes first`() {
        var carry = TrackCarryOver()
        carry.audio = Track(languageTag: "jpn", label: "Japanese")
        #expect(carry.audioLanguages(over: ["de", "en"]) == ["ja", "de", "en"])
    }

    @Test func `the picked audio language is not listed twice`() {
        var carry = TrackCarryOver()
        carry.audio = Track(languageTag: "eng", label: nil)
        #expect(carry.audioLanguages(over: ["de", "en"]) == ["en", "de"])
    }

    @Test func `an unlabelled audio pick leaves the preferred languages alone`() {
        var carry = TrackCarryOver()
        carry.audio = Track(languageTag: nil, label: nil)
        #expect(carry.audioLanguages(over: ["de"]) == ["de"])
    }

    // MARK: - Subtitles

    private let tracks = [
        Candidate(track: Track(languageTag: "eng", label: "English"), isForced: true),
        Candidate(track: Track(languageTag: "eng", label: "English")),
        Candidate(track: Track(languageTag: "eng", label: "English SDH")),
        Candidate(track: Track(languageTag: "ger", label: "Deutsch"))
    ]

    @Test func `no subtitle pick keeps the engine's choice`() {
        #expect(TrackCarryOver().resolveSubtitle(in: tracks) == .keep)
    }

    @Test func `subtitles turned off stay off`() {
        var carry = TrackCarryOver()
        carry.subtitle = .off
        #expect(carry.resolveSubtitle(in: tracks) == .off)
        #expect(carry.resolveSubtitle(in: []) == .off)
    }

    @Test func `a full track lands on the full track in its language`() {
        var carry = TrackCarryOver()
        carry.subtitle = .track(Track(languageTag: "en", label: nil), isForced: false)
        #expect(carry.resolveSubtitle(in: tracks) == .select(1))
    }

    @Test func `the exact label wins, so SDH stays SDH`() {
        var carry = TrackCarryOver()
        carry.subtitle = .track(Track(languageTag: "eng", label: "English SDH"), isForced: false)
        #expect(carry.resolveSubtitle(in: tracks) == .select(2))
    }

    @Test func `a label match must also match the language`() {
        var carry = TrackCarryOver()
        carry.subtitle = .track(Track(languageTag: "ger", label: "English"), isForced: false)
        #expect(carry.resolveSubtitle(in: tracks) == .select(3))
    }

    @Test func `a forced pick lands on the forced track`() {
        var carry = TrackCarryOver()
        carry.subtitle = .track(Track(languageTag: "eng", label: "English"), isForced: true)
        #expect(carry.resolveSubtitle(in: tracks) == .select(0))
    }

    @Test func `a forced pick never lands on a full track`() {
        var carry = TrackCarryOver()
        carry.subtitle = .track(Track(languageTag: "ger", label: nil), isForced: true)
        #expect(carry.resolveSubtitle(in: tracks) == .keep)
    }

    @Test func `a full pick falls back to a forced track in its language`() {
        var carry = TrackCarryOver()
        carry.subtitle = .track(Track(languageTag: "fre", label: "Français"), isForced: false)
        let candidates = [
            Candidate(track: Track(languageTag: "eng", label: nil)),
            Candidate(track: Track(languageTag: "fre", label: "Forced"), isForced: true)
        ]
        #expect(carry.resolveSubtitle(in: candidates) == .select(1))
    }

    @Test func `the language comes from the label when the tag is missing`() {
        var carry = TrackCarryOver()
        carry.subtitle = .track(Track(languageTag: "spa", label: nil), isForced: false)
        let candidates = [
            Candidate(track: Track(languageTag: nil, label: "English")),
            Candidate(track: Track(languageTag: nil, label: "Spanish"))
        ]
        #expect(carry.resolveSubtitle(in: candidates) == .select(1))
    }

    @Test func `no track in the carried language keeps the engine's choice`() {
        var carry = TrackCarryOver()
        carry.subtitle = .track(Track(languageTag: "ita", label: "Italiano"), isForced: false)
        #expect(carry.resolveSubtitle(in: tracks) == .keep)
        #expect(carry.resolveSubtitle(in: []) == .keep)
    }

    @Test func `an unlabelled pick keeps the engine's choice`() {
        var carry = TrackCarryOver()
        carry.subtitle = .track(Track(languageTag: nil, label: nil), isForced: false)
        #expect(carry.resolveSubtitle(in: tracks) == .keep)
    }

    // MARK: - Fixtures

    private func media(_ ref: PlayableMedia.ContentRef, kind: PlayableMedia.Kind = .vod) throws -> PlayableMedia {
        let id: String = switch ref {
        case let .movie(value), let .episode(value), let .live(value), let .recording(value):
            value
        }
        return try PlayableMedia(
            id: id,
            url: #require(URL(string: "http://example.com/\(id).mkv")),
            title: id,
            subtitle: nil,
            posterURL: nil,
            kind: kind,
            startTime: 0,
            contentRef: ref
        )
    }
}

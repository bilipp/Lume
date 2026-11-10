//
//  TrackCarryOver.swift
//  Lume
//
//  The audio and subtitle picks a viewer made by hand, carried from one stream
//  into the next one where they still mean something: the next episode of a
//  series, or a fresh session of the same stream (stall recovery).
//
//  KSPlayer gets this for free from its own subtitle auto-select; LumeEngine
//  and AetherEngine open every stream from scratch, so without a carry the
//  next episode starts with subtitles off and the container's audio.
//
//  Matched by language, not by index: track order and stream indices differ
//  from file to file, and an index from the last episode can name a different
//  language (or nothing) in this one. Lives on the engine's coordinator, which
//  stays mounted across episode swaps; persisted nowhere.
//

import Foundation

nonisolated struct TrackCarryOver: Equatable {
    typealias Track = TrackLanguageMatcher.Track

    enum Subtitle: Equatable {
        /// The viewer turned subtitles off.
        case off
        case track(Track, isForced: Bool)
    }

    /// A subtitle track the new stream offers, in the engine's track order.
    struct Candidate: Equatable {
        let track: Track
        let isForced: Bool

        init(track: Track, isForced: Bool = false) {
            self.track = track
            self.isForced = isForced
        }
    }

    enum SubtitleResolution: Equatable {
        /// Leave whatever the engine picked: nothing was carried, or the new
        /// stream has no track in the carried language.
        case keep
        case off
        /// Index into the candidates.
        case select(Int)
    }

    /// The audio track picked by hand, if any.
    var audio: Track?
    /// The subtitle choice made by hand, if any. `nil` is not `.off`: it
    /// means the viewer never touched the menu.
    var subtitle: Subtitle?

    var isEmpty: Bool {
        audio == nil && subtitle == nil
    }

    /// Whether picks made on `previous` still apply to `next`: the same stream
    /// again, or one episode after another. A movie or a channel starts from
    /// the viewer's preferences instead — a subtitle picked for one film says
    /// nothing about the next, and live channels change language with the
    /// channel.
    static func carries(from previous: PlayableMedia?, to next: PlayableMedia) -> Bool {
        guard let previous else { return false }
        if previous.url == next.url {
            return true
        }
        if case .episode = previous.contentRef, case .episode = next.contentRef {
            return true
        }
        return false
    }

    // MARK: Audio

    /// The preferred audio languages with the carried pick's language first.
    /// `preferred` alone when nothing was picked or the pick names no
    /// language — an unlabelled track can't be found again in another file.
    func audioLanguages(over preferred: [String]) -> [String] {
        guard let code = audio.flatMap(Self.languageCode(of:)) else { return preferred }
        return [code] + preferred.filter { TrackLanguageMatcher.normalize($0) != code }
    }

    // MARK: Subtitles

    /// What to do with the new stream's subtitles.
    ///
    /// The carried track is found again by its exact label first (so `English
    /// SDH` stays SDH rather than becoming plain English), then by language.
    /// A forced pick only ever lands on a forced track; a full one prefers a
    /// full track and falls back to a forced one in the same language.
    func resolveSubtitle(in candidates: [Candidate]) -> SubtitleResolution {
        switch subtitle {
        case nil:
            .keep
        case .off:
            .off
        case let .track(track, isForced):
            Self.match(track, isForced: isForced, in: candidates).map(SubtitleResolution.select) ?? .keep
        }
    }

    private static func match(_ track: Track, isForced: Bool, in candidates: [Candidate]) -> Int? {
        let code = languageCode(of: track)
        let label = normalizedLabel(track.label)
        let sameKind = candidates.indices.filter { candidates[$0].isForced == isForced }

        if let label,
           let index = sameKind.first(where: {
               normalizedLabel(candidates[$0].track.label) == label
                   && languageCode(of: candidates[$0].track) == code
           })
        {
            return index
        }
        guard let code else { return nil }

        if let index = bestMatch(of: code, among: sameKind, in: candidates) {
            return index
        }
        guard !isForced else { return nil }
        return bestMatch(of: code, among: Array(candidates.indices), in: candidates)
    }

    private static func bestMatch(of code: String, among indices: [Int], in candidates: [Candidate]) -> Int? {
        let tracks = indices.map { candidates[$0].track }
        return TrackLanguageMatcher.bestMatchIndex(in: tracks, preferring: [code]).map { indices[$0] }
    }

    private static func languageCode(of track: Track) -> String? {
        track.languageTag.flatMap(TrackLanguageMatcher.normalize)
            ?? track.label.flatMap(TrackLanguageMatcher.normalize)
    }

    private static func normalizedLabel(_ label: String?) -> String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}

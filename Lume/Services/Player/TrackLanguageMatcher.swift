//
//  TrackLanguageMatcher.swift
//  Lume
//
//  Ordered language-preference matching over the audio / subtitle tracks a
//  container advertises, shared by all four engines.
//
//  Foundation only, and deliberately outside every engine-guarded file: the
//  test target links none of KSPlayer, VLCKit or LumeEngine, so anything that
//  imported one would be untestable. Each engine adapts its own track type to
//  `Track` at the call site instead.
//
//  A same-named matcher exists inside the LumeEngine package. That one runs
//  engine-side while the pipeline is being built and takes already-normalised
//  codes; this is the app-side copy that also has to cope with raw container
//  tags and free-text track names. They are intentionally separate.
//
//  Every entry point is `nonisolated`: matching runs from
//  `KSOptions.wantedAudio(tracks:)` (an open nonisolated override) and from
//  VLCKit's own delegate thread.
//

import Foundation

nonisolated enum TrackLanguageMatcher {
    /// One track, reduced to what language matching needs.
    ///
    /// Both fields matter: KSPlayer puts the container tag on `languageCode`
    /// and free text like `Deutsch` on `name`, and plenty of IPTV muxes carry
    /// no tag at all and spell the language out in the title instead.
    ///
    /// The container's own default disposition is deliberately not an input —
    /// a viewer's preference outranks it, so callers apply whatever this
    /// returns over the default the engine would otherwise have picked.
    nonisolated struct Track: Equatable {
        /// The container's language tag, e.g. `ger`, `deu`, `de-AT`.
        let languageTag: String?
        /// The track's display name, e.g. `Deutsch`, `GER 5.1`, `English AD`.
        let label: String?

        init(languageTag: String? = nil, label: String? = nil) {
            self.languageTag = languageTag
            self.label = label
        }
    }

    // MARK: - Matching

    /// Index of the track that best satisfies an ordered preference list, or
    /// `nil` when nothing matches.
    ///
    /// `nil` means *do nothing*: the container's own selection stands. It must
    /// never be turned into index 0 by a caller — that would change playback
    /// for every stream whose languages the viewer never asked about.
    static func bestMatchIndex(in tracks: [Track], preferring languages: [String]) -> Int? {
        guard !tracks.isEmpty else { return nil }
        let wanted = normalizedPreferences(languages)
        guard !wanted.isEmpty else { return nil }

        var best: (score: Score, index: Int)?
        for (index, track) in tracks.enumerated() {
            guard let hit = score(track, order: index, against: wanted) else { continue }
            if let current = best, current.score <= hit {
                continue
            }
            best = (hit, index)
        }
        return best?.index
    }

    /// Whether the audio that ended up selected is foreign to the viewer,
    /// which is what gates auto-enabling a forced subtitle track.
    ///
    /// With the shipping default — an empty preferred-audio list — nothing is
    /// ever foreign, so the forced branch is unreachable until the viewer adds
    /// a language. A track whose language cannot be resolved at all (`und`, a
    /// bare `Track 1`) is not foreign either: nothing is known, so nothing
    /// should turn itself on.
    static func isForeign(_ track: Track, comparedTo preferredAudioLanguages: [String]) -> Bool {
        let wanted = normalizedPreferences(preferredAudioLanguages)
        guard !wanted.isEmpty else { return false }

        let tagCode = track.languageTag.flatMap(code(fromTag:))
        if let tagCode, wanted.contains(tagCode) { return false }
        let labelCodes = track.label.map(codes(inFreeText:)) ?? []
        if labelCodes.contains(where: wanted.contains) { return false }
        return tagCode != nil || !labelCodes.isEmpty
    }

    // MARK: - Normalization

    /// Reduces anything a container might carry — `ger`, `deu`, `de-DE`,
    /// `de_DE`, `Deutsch`, `German`, `GER 5.1`, `Audio 1 - English` — to a bare
    /// `de`-style code, or `nil` when it names no single language.
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let code = code(fromTag: trimmed) {
            return code
        }
        return codes(inFreeText: trimmed).first
    }

    /// The language in the viewer's own language, falling back to the raw code
    /// for regional variants (`pt-br`, `zh-cn`) the system doesn't name.
    static func displayName(for code: String) -> String {
        if let name = Locale.current.localizedString(forIdentifier: code) {
            return name
        }
        if let name = Locale.current.localizedString(forLanguageCode: code) {
            return name
        }
        return code.uppercased()
    }

    // MARK: - Scoring

    /// Ranked quality of one track↔preference hit. Lower is better, and the
    /// fields are compared in declaration order:
    ///
    /// 1. `rank` — position in the viewer's ordered preference list.
    /// 2. `penalty` — commentary / audio-description tracks lose to a plain
    ///    track of the same language.
    /// 3. `quality` — an exact bare tag beats a regional variant (`de` over
    ///    `de-AT`), which beats a language found in free text.
    /// 4. `order` — container order; first match wins all else being equal.
    private struct Score: Comparable {
        let rank: Int
        let penalty: Int
        let quality: Int
        let order: Int

        static func < (lhs: Score, rhs: Score) -> Bool {
            (lhs.rank, lhs.penalty, lhs.quality, lhs.order) < (rhs.rank, rhs.penalty, rhs.quality, rhs.order)
        }
    }

    private static func score(_ track: Track, order: Int, against wanted: [String]) -> Score? {
        let penalty = isDeprioritized(track) ? 1 : 0

        if let tag = track.languageTag, let canonical = code(fromTag: tag), let rank = wanted.firstIndex(of: canonical) {
            return Score(rank: rank, penalty: penalty, quality: hasSubtags(tag) ? 1 : 0, order: order)
        }

        if let label = track.label {
            let ranks = codes(inFreeText: label).compactMap { wanted.firstIndex(of: $0) }
            if let rank = ranks.min() {
                return Score(rank: rank, penalty: penalty, quality: 2, order: order)
            }
        }

        return nil
    }

    /// Labels meaning "not the feature audio": director commentary and audio
    /// description. Matched on the label, because no engine surfaces FFmpeg's
    /// comment / visual-impaired disposition.
    private static func isDeprioritized(_ track: Track) -> Bool {
        guard let label = track.label?.lowercased() else { return false }
        for phrase in commentaryPhrases where label.contains(phrase) {
            return true
        }
        // "English AD" — the abbreviation counts only as a standalone token.
        return tokens(of: label).contains("ad")
    }

    private static let commentaryPhrases = [
        "commentary", "commentaire", "kommentar", "comentario", "comentário",
        "commento", "audio description", "audiodescription", "audiodescricao",
        "audiodescrição", "audiodescripcion", "audiodescripción", "descriptive",
        "described", "hörfilm"
    ]

    // MARK: - Language tags

    /// The viewer's preferences as ordered, de-duplicated bare codes.
    private static func normalizedPreferences(_ languages: [String]) -> [String] {
        PreferredLanguageList.normalized(languages.compactMap(normalize))
    }

    /// A single language tag reduced to its primary subtag, or `nil` when it
    /// carries no usable language.
    ///
    /// `Locale.LanguageCode` only knows the ISO 639-2/T terminology codes —
    /// `Locale.LanguageCode("deu").identifier(.alpha2)` is `de`, but the same
    /// call on the 639-2/B bibliographic code `ger` is `nil`, and `ger` is what
    /// MKV and MPEG-TS actually carry. Hence the table below; it covers every
    /// /B code that differs from its /T form.
    private static func code(fromTag tag: String) -> String? {
        let lowered = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let primary = lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init),
              primary.allSatisfy(\.isLetter),
              !placeholders.contains(primary)
        else { return nil }

        switch primary.count {
        case 2:
            return Locale.LanguageCode(primary).isISOLanguage ? primary : nil
        case 3:
            if let alpha2 = bibliographicAlpha2[primary] {
                return alpha2
            }
            let candidate = Locale.LanguageCode(primary)
            guard candidate.isISOLanguage else { return nil }
            return candidate.identifier(.alpha2) ?? primary
        default:
            return nil
        }
    }

    /// Languages named in a free-text label, best candidate first. Matched per
    /// token rather than by substring: a bare `de` occurs inside half the
    /// Romance track titles ever written.
    private static func codes(inFreeText text: String) -> [String] {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return [] }
        let tokens = tokens(of: lowered)

        var seen = Set<String>()
        var result: [String] = []
        func add(_ code: String?) {
            guard let code, seen.insert(code).inserted else { return }
            result.append(code)
        }

        add(languageNamesToCodes[lowered])
        for token in tokens {
            add(languageNamesToCodes[token])
        }
        for token in tokens {
            add(code(fromTag: token))
        }
        return result
    }

    /// True when the tag names a region or script beyond the language itself
    /// (`de-AT`), which loses to an exact `de` when both are present.
    private static func hasSubtags(_ tag: String) -> Bool {
        tag.contains("-") || tag.contains("_")
    }

    private static func tokens(of text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Tags asserting the absence of one language. `vo` / `vost` are French
    /// broadcast shorthand for "version originale" (not Volapük, which no IPTV
    /// provider has ever muxed) and `multi` is the IPTV convention for a
    /// multiplexed track. All of them mean no match, so the container's own
    /// choice stands.
    private static let placeholders: Set<String> = [
        "und", "mul", "mis", "zxx", "vo", "vos", "vost", "multi", "original", "unknown"
    ]

    /// ISO 639-2/B → 639-1: exactly the codes `Locale.LanguageCode` cannot
    /// resolve because it only knows the terminological forms.
    private static let bibliographicAlpha2: [String: String] = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh",
        "cze": "cs", "dut": "nl", "fre": "fr", "geo": "ka", "ger": "de",
        "gre": "el", "ice": "is", "mac": "mk", "may": "ms", "mao": "mi",
        "per": "fa", "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy"
    ]

    /// Localized language names → bare code, built once from the ISO list in
    /// English, in the device language, and in each language's own name (a
    /// German track is labelled `Deutsch` far more often than `German`).
    /// Roughly 20 ms to build, and only ever touched by the free-text path.
    private static let languageNamesToCodes: [String: String] = {
        let sources = [Locale(identifier: "en"), Locale.current]
        var index: [String: String] = [:]
        func insert(_ locale: Locale, naming identifier: String, as canonical: String) {
            guard let name = locale.localizedString(forLanguageCode: identifier)?.lowercased(),
                  index[name] == nil
            else { return }
            index[name] = canonical
        }
        for language in Locale.LanguageCode.isoLanguageCodes where language.isISOLanguage {
            let canonical = language.identifier(.alpha2) ?? language.identifier
            for locale in sources {
                insert(locale, naming: language.identifier, as: canonical)
            }
            insert(Locale(identifier: canonical), naming: language.identifier, as: canonical)
        }
        return index
    }()
}

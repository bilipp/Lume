import Foundation

/// The picture quality a provider advertises in a live channel's name
/// ("DE: Lume Sport 1 FHD", "Northbeam One ᴴᴰ", "Pitchside (1080p)"). Untagged names
/// have no quality and order like `.sd`.
nonisolated enum ChannelQuality: Comparable {
    // swiftlint:disable:next identifier_name - the tags providers print.
    case sd, hd, fhd, uhd

    /// Splits a channel name into the key its quality variants share and the
    /// quality tag it carries.
    ///
    /// Providers name the channel first and describe the feed after it, so
    /// everything from the first quality tag on is the tag: "Fieldcast 1 HDraw
    /// Cable", "Fieldcast 1 FHD Low (HEVC)" and "Fieldcast 1 HD (Web)" all key to
    /// "fieldcast 1". A tag may carry a glued suffix ("HDraw", "FHD+", "HD²") but
    /// otherwise matches a whole word, so "HD" never matches inside UHDTV or
    /// "Shdtv". Channel numbers and "+1" timeshift markers after the tag stay
    /// in the key ("Lume Sport HD 1", "Lume Eins HD +1"), as do country prefixes.
    static func parse(_ name: String) -> (key: String, quality: ChannelQuality?, tag: String?) {
        let segments = segments(of: name)
        guard let start = segments.firstIndex(where: { tagToken(in: $0) != nil }) else {
            return (key: cleanedKey(name), quality: nil, tag: nil)
        }
        let core = segments[..<start].map(\.text).joined()
        // A name that opens with its tag ("|HD| Pitchside 1", "DE: HD Lume")
        // has no channel before it; strip the tokens wherever they sit instead.
        guard !isPrefixOnly(core) else { return strippingTokens(from: name) }

        let tail = segments[start...]
        let kept = tail.filter { tagToken(in: $0) == nil && $0.text.wholeMatch(of: keptTailWord) != nil }
        let key = cleanedKey(([trimmingTrailers(core)] + kept.map(\.text)).joined(separator: " "))
        let tag = balancingBrackets(tail.map(\.text).joined()).trimmingCharacters(in: .whitespaces)
        return (
            key: key.isEmpty ? cleanedKey(name) : key,
            quality: tail.compactMap { tagToken(in: $0)?.quality }.max(),
            tag: tag.isEmpty ? nil : tag
        )
    }

    /// The token naming the highest quality above SD in `name`, uppercased and
    /// with superscripts spelled in ASCII ("ᶠᴴᴰ" reads "FHD", "FHD+" reads
    /// "FHD"). On a tie the first one wins, so "Lume 4K UHD" reads "4K".
    static func badge(for name: String) -> String? {
        var best: (token: String, quality: ChannelQuality)?
        for segment in segments(of: name) {
            guard let token = tagToken(in: segment), let quality = token.quality, quality > .sd,
                  best.map({ quality > $0.quality }) ?? true
            else { continue }
            best = (token.base, quality)
        }
        return best?.token
    }
}

// MARK: - Tokens

private nonisolated extension ChannelQuality {
    struct Token {
        let quality: ChannelQuality?
    }

    enum SegmentKind {
        case word, superscript, separator
    }

    struct Segment {
        let kind: SegmentKind
        var text: String
    }

    static let marker: Character = "\u{1F}"

    /// The tag `segment` names, if any, with the table spelling of its token:
    /// a whole token ("FHD", "ᴴᴰ", "HEVC") or a quality token with a glued
    /// RAW, "+" or superscript-digit suffix ("HDraw²", "FHD+").
    static func tagToken(in segment: Segment) -> (base: String, quality: ChannelQuality?)? {
        guard segment.kind != .separator else { return nil }
        let text = normalized(segment.text)
        if let token = tokenTable[text] { return (text, token.quality) }
        guard let match = text.wholeMatch(of: gluedTag) else { return nil }
        let base = String(match.output.1)
        return tokenTable[base].map { (base, $0.quality) }
    }

    static let gluedTag = /(UHD|FHD|HD|SD|4K|8K|\d{3,4}P)(?:RAW)?[+²³¹⁰-⁹]*/

    /// After the tag, a bare channel number or a "+1" timeshift marker still
    /// names the channel.
    static let keptTailWord = /\+?\d{1,3}/

    /// The channel before its tag, without the separator or opening bracket
    /// the tag followed ("Fieldcast 1 (" for "Fieldcast 1 (HEVC)").
    static func trimmingTrailers(_ core: String) -> String {
        var trimmed = Substring(core)
        while let last = trimmed.last, " ([{|-/·,_:".contains(last) {
            trimmed.removeLast()
        }
        return String(trimmed)
    }

    /// Nothing but a country or provider prefix ("DE: ", "|UK| ", "") before
    /// the tag.
    static func isPrefixOnly(_ core: String) -> Bool {
        guard core.contains(where: { $0.isLetter || $0.isNumber }) else { return true }
        return core.wholeMatch(of: /\W*[A-Za-z]{2,4}\W*/) != nil && core.contains { ":|[".contains($0) }
    }

    /// Drops closing brackets the tag cut from their opener ("1080p)").
    static func balancingBrackets(_ text: String) -> String {
        var depth = 0
        return String(text.filter { character in
            if "([{".contains(character) { depth += 1 }
            guard ")]}".contains(character) else { return true }
            guard depth > 0 else { return false }
            depth -= 1
            return true
        })
    }

    /// Masks whole tokens wherever they sit, for a name with no channel before
    /// its tag.
    static func strippingTokens(from name: String) -> (key: String, quality: ChannelQuality?, tag: String?) {
        var masked = ""
        var tags: [String] = []
        var quality: ChannelQuality?
        for segment in segments(of: name) {
            guard segment.kind != .separator, let token = tokenTable[normalized(segment.text)] else {
                masked += segment.text
                continue
            }
            masked.append(marker)
            tags.append(segment.text)
            if let tokenQuality = token.quality {
                quality = max(quality ?? tokenQuality, tokenQuality)
            }
        }
        let key = cleanedKey(masked)
        return (
            key: key.isEmpty ? cleanedKey(name) : key,
            quality: quality,
            tag: tags.isEmpty ? nil : tags.joined(separator: " ")
        )
    }

    static let tokenTable: [String: Token] = {
        var table: [String: Token] = [:]
        let groups: [(ChannelQuality?, [String])] = [
            (.uhd, ["4K", "8K", "UHD", "2160P"]),
            (.fhd, ["FHD", "1080P"]),
            (.hd, ["HD", "720P"]),
            (.sd, ["SD", "576P", "480P"]),
            (nil, ["HEVC", "H265", "H.265", "HDR", "50FPS", "60FPS"])
        ]
        for (quality, words) in groups {
            for word in words {
                table[word] = Token(quality: quality)
            }
        }
        return table
    }()

    static let superscripts: [Character: Character] = [
        "ᴴ": "H", "ᴰ": "D", "ᶠ": "F", "ᵁ": "U", "ˢ": "S", "ᴿ": "R", "ᴷ": "K", "⁴": "4", "⁸": "8"
    ]

    static func normalized(_ text: String) -> String {
        String(text.map { superscripts[$0] ?? $0 }).uppercased()
    }

    /// Runs of word characters, superscripts and everything else. A superscript
    /// run is its own segment, so "LMXᴴᴰ" splits into "LMX" and "ᴴᴰ"; a dot
    /// stays inside a word only before a digit ("H.265").
    static func segments(of name: String) -> [Segment] {
        let characters = Array(name)
        var result: [Segment] = []
        for (index, character) in characters.enumerated() {
            let kind: SegmentKind = if superscripts[character] != nil {
                .superscript
            } else if character.isLetter || character.isNumber || character == "+" {
                .word
            } else if character == ".", result.last?.kind == .word,
                      index + 1 < characters.count, characters[index + 1].isNumber
            {
                .word
            } else {
                .separator
            }
            if let last = result.last, last.kind == kind {
                result[result.count - 1].text.append(character)
            } else {
                result.append(Segment(kind: kind, text: String(character)))
            }
        }
        return result
    }

    /// Drops the bracket or separator pair a removed token sat in ("(1080p)",
    /// "|HD|", "- HD -"), then folds case and diacritics and collapses spaces.
    /// A pipe only trims at an end when spaced off, so "|UK|" keeps both.
    static func cleanedKey(_ masked: String) -> String {
        let bracketed = masked
            .replacing(bracketedTokens, with: " ")
            .replacing(pipedTokens, with: " ")
        let sandwiched = bracketed.replacing(sandwichedTokens) { match in
            match.output.1
        }
        let folded = sandwiched
            .replacing(String(marker), with: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: keySeparators)
            .replacing(spacedEndPipe, with: "")
            .trimmingCharacters(in: keySeparators)
    }

    static let bracketedTokens = /[(\[{]\s*\x{1F}(?:[\s\/,·\-]*\x{1F})*\s*[)\]}]/
    static let pipedTokens = /\|\x{1F}(?:[\s\/,·\-]*\x{1F})*\|/
    static let sandwichedTokens = /([\-|\/·])\s*\x{1F}(?:[\s\/,·\-]*\x{1F})*\s*\1/
    static let spacedEndPipe = /^\|\s|\s\|$/
    static let keySeparators = CharacterSet(charactersIn: " -/·,_:")
}

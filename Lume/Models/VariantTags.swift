//
//  VariantTags.swift
//  Lume
//
//  What a provider's movie/series title says about one copy of a title: its
//  quality, HDR / Dolby Vision, and language ("DE | Der Pate (1972) 4K HDR",
//  "Inception [ENG] FHD"). Ranks the copies of a grouped title against each
//  other.
//

import Foundation

nonisolated struct VariantTags: Hashable {
    /// `nil` when the title names no quality; that ranks like SD.
    let quality: ChannelQuality?
    let isHDR: Bool
    let isDolbyVision: Bool
    /// Bare ISO 639-1 code (`de`), from the title, else the category name.
    let languageCode: String?
    /// The quality as shown to the viewer: 4K, UHD, FHD, HD or SD.
    let qualityLabel: String?

    init(title: String, categoryName: String? = nil) {
        let tokens = Self.tokens(of: title)
        let quality = ChannelQuality.parse(title).quality
        self.quality = quality
        qualityLabel = quality.map { Self.label(for: $0, title: title) }
        isHDR = tokens.contains { Self.hdrTokens.contains($0) }
        isDolbyVision = tokens.contains { Self.dolbyVisionTokens.contains($0) }
            || title.range(of: "dolby vision", options: .caseInsensitive) != nil
        languageCode = Self.taggedLanguage(in: title)
            ?? categoryName.flatMap { Self.taggedLanguage(in: $0) ?? Self.namedLanguage(in: $0) }
    }

    /// Orders copies of one title: ascending sorts the best first. Quality
    /// leads, then the position of the copy's language in `preferredLanguages`
    /// (the viewer's ordered preferred audio languages); copies in no
    /// preferred language come last within their quality.
    struct Rank: Comparable {
        let quality: Int
        let language: Int

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            return lhs.language < rhs.language
        }
    }

    func rank(preferredLanguages: [String]) -> Rank {
        let preferred = PreferredLanguageList.normalized(preferredLanguages.compactMap(TrackLanguageMatcher.normalize))
        let language = languageCode.flatMap { code in
            preferred.firstIndex { $0.caseInsensitiveCompare(code) == .orderedSame }
        } ?? preferred.count
        return Rank(quality: Self.qualityScore(quality), language: language)
    }
}

private nonisolated extension VariantTags {
    static func qualityScore(_ quality: ChannelQuality?) -> Int {
        switch quality {
        case .uhd: 3
        case .fhd: 2
        case .hd: 1
        case .sd, nil: 0
        }
    }

    static func label(for quality: ChannelQuality, title: String) -> String {
        switch quality {
        case .uhd: ChannelQuality.badge(for: title) == "UHD" ? "UHD" : "4K"
        case .fhd: "FHD"
        case .hd: "HD"
        case .sd: "SD"
        }
    }

    static let hdrTokens: Set<String> = ["HDR", "HDR10", "HDR10+", "HLG"]
    static let dolbyVisionTokens: Set<String> = ["DV", "DOVI", "DOLBYVISION"]

    /// Uppercased runs of letters, digits and "+".
    static func tokens(of text: String) -> [String] {
        text.uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" })
            .map(String.init)
    }

    /// A language the provider tagged explicitly: an all-caps prefix before a
    /// separator ("DE | …", "EN - …", "FR: …") or a bracketed tag anywhere
    /// ("[GER]", "(ENG)", "|FR|"). Bare words in a title never count — "It",
    /// "Die Hard" and "The French Connection" name no language.
    static func taggedLanguage(in text: String) -> String? {
        var candidates: [String] = []
        if let match = text.firstMatch(of: leadingTag) {
            candidates.append(String(match.output.1))
        }
        candidates += text.matches(of: bracketedTag).map { String($0.output.1) }
        for candidate in candidates {
            if let code = languageCode(forTag: candidate) { return code }
        }
        return nil
    }

    static let leadingTag = /^\s*[\[(|]?\s*([A-Z]{2,3})\s*(?:[\])|:•]|\s-\s)/
    static let bracketedTag = /[\[(|]\s*([A-Za-z]{2,3})\s*[\])|]/

    static func languageCode(forTag tag: String) -> String? {
        let upper = tag.uppercased()
        if let code = providerTags[upper] { return code }
        guard !nonLanguageTags.contains(upper) else { return nil }
        return TrackLanguageMatcher.normalize(tag)
    }

    /// A language spelled out in a category name ("German Movies", "Filme
    /// Deutsch"). Words of four letters or more only, so short codes go
    /// through the tag rules above.
    static func namedLanguage(in text: String) -> String? {
        text.split(whereSeparator: { !$0.isLetter })
            .lazy
            .filter { $0.count >= 4 }
            .compactMap { TrackLanguageMatcher.normalize(String($0)) }
            .first
    }

    /// Country prefixes providers use in place of a language code, and the
    /// ones whose letters are a different ISO language ("SE" is Northern Sami,
    /// "UK" Ukrainian).
    static let providerTags: [String: String] = [
        "UK": "en", "US": "en", "USA": "en", "GB": "en",
        "SE": "sv", "DK": "da", "GR": "el", "JP": "ja", "KR": "ko",
        "CN": "zh", "BR": "pt", "CZ": "cs", "AL": "sq", "RS": "sr",
        "IR": "fa", "IL": "he", "AT": "de", "LAT": "es",
        "VF": "fr", "VFF": "fr", "VFQ": "fr"
    ]

    /// Quality, codec and catalogue tags that happen to be ISO codes ("SD"
    /// Sindhi, "DV" Divehi).
    static let nonLanguageTags: Set<String> = [
        "SD", "HD", "FHD", "UHD", "DV", "HDR", "TV", "VOD", "NEW", "TOP", "SUB", "DUB", "CAM", "TS"
    ]
}

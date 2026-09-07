//
//  PreferredLanguageCatalog.swift
//  Lume
//
//  The language catalogue behind the preferred audio / subtitle pickers. Built
//  entirely from `Locale`, never from OpenSubtitles: `OpenSubtitlesClient
//  .languages()` throws `.notConfigured` without the gitignored `.env` key, so
//  a network-sourced catalogue would leave the picker empty offline and in any
//  clone without that file.
//

import Foundation

/// One selectable language: a bare code plus its name in the viewer's language.
nonisolated struct PreferredLanguage: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String {
        code
    }

    init(code: String) {
        self.code = code
        name = TrackLanguageMatcher.displayName(for: code)
    }

    init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

nonisolated enum PreferredLanguageCatalog {
    /// The languages IPTV providers actually ship audio and subtitle tracks in,
    /// roughly by how often they turn up. Shown up front so the common case
    /// never needs the search field.
    static let shortlistCodes: [String] = [
        "en", "es", "fr", "de", "it", "pt", "ru", "ar", "hi", "zh",
        "ja", "ko", "tr", "nl", "pl", "sv", "no", "da", "fi", "el",
        "cs", "sk", "hu", "ro", "bg", "uk", "sr", "hr", "he", "fa",
        "ur", "bn", "ta", "th", "vi", "id", "ms", "tl", "sw", "af",
        "ca", "sq"
    ]

    /// The curated shortlist, named and ordered for display.
    static let shortlist: [PreferredLanguage] = sortedByName(shortlistCodes.map(PreferredLanguage.init(code:)))

    /// The languages the device is set up for, offered at the top of the add
    /// picker. A SUGGESTION ONLY — nothing here is ever written to the stored
    /// preference, which ships empty and stays empty until the viewer picks.
    static let suggestions: [PreferredLanguage] = {
        let codes = Locale.preferredLanguages.compactMap(TrackLanguageMatcher.normalize)
        return PreferredLanguageList.normalized(codes).map(PreferredLanguage.init(code:))
    }()

    /// What the add picker can still offer, in the two groups it shows: the
    /// device's own languages, then the curated shortlist minus those. Both
    /// exclude what the viewer already picked.
    static func addable(
        excluding selected: [String]
    ) -> (suggested: [PreferredLanguage], common: [PreferredLanguage]) {
        let suggested = available(suggestions, excluding: selected)
        let offered = Set(suggested.map(\.code))
        return (suggested, available(shortlist, excluding: selected).filter { !offered.contains($0.code) })
    }

    /// The subset of `languages` the viewer hasn't already picked.
    static func available(_ languages: [PreferredLanguage], excluding selected: [String]) -> [PreferredLanguage] {
        let picked = Set(selected.map { $0.lowercased() })
        return languages.filter { !picked.contains($0.code.lowercased()) }
    }

    /// Every ISO language the system can name, plus the shortlist. Backs the
    /// picker's search field.
    static let all: [PreferredLanguage] = {
        var seen = Set<String>()
        var result: [PreferredLanguage] = []
        for language in Locale.LanguageCode.isoLanguageCodes {
            let code = language.identifier(.alpha2) ?? language.identifier
            guard seen.insert(code).inserted,
                  let name = Locale.current.localizedString(forLanguageCode: code)
            else { continue }
            result.append(PreferredLanguage(code: code, name: name))
        }
        for code in shortlistCodes where seen.insert(code).inserted {
            result.append(PreferredLanguage(code: code))
        }
        return sortedByName(result)
    }()

    /// Name- or code-matched subset of `all`, for the picker's search field.
    static func search(_ query: String) -> [PreferredLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowered = trimmed.lowercased()
        return all.filter {
            $0.code.hasPrefix(lowered) || $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private static func sortedByName(_ languages: [PreferredLanguage]) -> [PreferredLanguage] {
        languages.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

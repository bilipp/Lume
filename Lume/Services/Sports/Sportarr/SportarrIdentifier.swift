//
//  SportarrIdentifier.swift
//  Lume
//
//  Explicit identifiers only: provider fields, frozen TVDB aliases and the
//  published Sportarr filename token grammar. Titles, tags and library names
//  never classify a file. Every source adapter funnels through `reference`, so
//  the stored `sportsRef` means the same thing whatever server supplied it.
//

import Foundation

nonisolated enum SportarrIdentifier {
    /// Sportarr's published URI scheme; the stored form of a `sportsRef`.
    static let scheme = "sportarr://"

    enum Kind { case event, league }

    /// Whether a stored `sportsRef` names one exact event, not only a league.
    static func isEvent(_ reference: String?) -> Bool {
        reference?.hasPrefix(scheme + "ev-") == true
    }

    /// The value a row's `sportsRef` should hold after this observation:
    /// evidence writes it, an observed miss clears it, and a response that
    /// never carried the evidence fields leaves `current` alone.
    static func reference(_ kind: Kind, providerIDs: [String: String]?, path: String?, observed: Bool, current: String?) -> String? {
        let id = kind == .event ? eventID(providerIDs: providerIDs, path: path) : leagueID(providerIDs: providerIDs, path: path)
        return id.map { scheme + $0 } ?? (observed ? nil : current)
    }

    static func eventID(providerIDs: [String: String]?, path: String?) -> String? {
        if let value = providerValue("Sportarr", in: providerIDs), canonical(value, prefix: "ev") != nil { return value.lowercased() }
        if let value = providerValue("Tvdb", in: providerIDs), let number = Int64(value), number >= 1_000_000_000 {
            return alias(number - 1_000_000_000, prefix: "ev")
        }
        return uniqueToken(in: path, prefix: "ev")
    }

    static func leagueID(providerIDs: [String: String]?, path: String? = nil) -> String? {
        if let value = providerValue("Sportarr", in: providerIDs), canonical(value, prefix: "lg") != nil { return value.lowercased() }
        if let value = providerValue("Tvdb", in: providerIDs), let number = Int64(value), (900_000_000 ..< 1_000_000_000).contains(number) {
            return alias(number - 900_000_000, prefix: "lg")
        }
        return uniqueToken(in: path, prefix: "lg")
    }

    static func canonical(_ value: String, prefix: String) -> String? {
        let lowered = value.lowercased()
        guard lowered.hasPrefix(prefix + "-") else { return nil }
        let digits = lowered.dropFirst(prefix.count + 1)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return lowered
    }

    private static func alias(_ number: Int64, prefix: String) -> String {
        let digits = String(number)
        return prefix + "-" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    /// Accepts the bare id and Sportarr's URI form alike.
    private static func providerValue(_ name: String, in ids: [String: String]?) -> String? {
        guard let value = ids?.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value else { return nil }
        return value.lowercased().hasPrefix(scheme) ? String(value.dropFirst(scheme.count)) : value
    }

    /// Ambiguous paths stay unresolved rather than choosing one game's token
    /// from a directory and another game's token from the filename.
    private static func uniqueToken(in path: String?, prefix: String) -> String? {
        guard let path else { return nil }
        let text = path.removingPercentEncoding ?? path
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        var identifiers = Set<String>()
        for expression in tokenExpressions {
            for match in expression.matches(in: text, range: range) {
                guard let prefixRange = Range(match.range(at: 1), in: text),
                      let digitsRange = Range(match.range(at: 2), in: text),
                      text[prefixRange].lowercased() == prefix else { continue }
                identifiers.insert(prefix + "-" + text[digitsRange])
            }
        }
        return identifiers.count == 1 ? identifiers.first : nil
    }

    /// Sportarr's release naming grammar: braced, branded, then strict bare
    /// tokens (6–10 digits and no space separator, so a year is not an ID).
    private static let tokenExpressions: [NSRegularExpression] = [
        #"\{\s*(?:sportarr[-._ ]*)?(ev|lg)[-._ ]*([0-9]{4,10})\s*\}"#,
        #"(?<![a-z0-9])sportarr[-._ ]+(ev|lg)[-._ ]*([0-9]{4,10})(?![0-9])"#,
        #"(?<![a-z0-9])(ev|lg)[-._]([0-9]{6,10})(?![0-9])"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
}

// MARK: - Source adapters

nonisolated extension JellyfinItem {
    /// Jellyfin, Emby, Silo and compatible servers: provider ids and the path.
    /// A response that carried neither field observed nothing.
    func sportsRef(_ kind: SportarrIdentifier.Kind, current: String?) -> String? {
        SportarrIdentifier.reference(kind, providerIDs: providerIds, path: path, observed: providerIds != nil || path != nil, current: current)
    }
}

nonisolated extension PlexMetadata {
    /// Plex: the external `Guid` array (`sportarr://…`, `tvdb://…`).
    func sportsRef(_ kind: SportarrIdentifier.Kind, current: String?) -> String? {
        let ids = ["Sportarr": providerId("sportarr"), "Tvdb": providerId("tvdb")].compactMapValues { $0 }
        return SportarrIdentifier.reference(kind, providerIDs: ids, path: nil, observed: guids != nil, current: current)
    }
}

nonisolated extension M3UEntry {
    /// Playlists and WebDAV: the entry URL is the only carrier, always present.
    func sportsRef(_ kind: SportarrIdentifier.Kind) -> String? {
        SportarrIdentifier.reference(kind, providerIDs: nil, path: url, observed: true, current: nil)
    }
}

//
//  SportarrIdentifier.swift
//  Lume
//
//  Explicit identifiers only: provider fields, frozen TVDB aliases and the
//  published Sportarr filename token grammar. Titles never classify a file.
//

import Foundation

nonisolated enum SportarrIdentifier {
    static func eventID(providerIDs: [String: String]?, path: String?) -> String? {
        if let value = providerValue("Sportarr", in: providerIDs), canonical(value, prefix: "ev") != nil { return value.lowercased() }
        if let value = providerValue("Tvdb", in: providerIDs), let number = Int64(value), number >= 1_000_000_000 {
            return alias(number - 1_000_000_000, prefix: "ev")
        }
        return uniqueToken(in: path, prefix: "ev")
    }

    static func leagueID(providerIDs: [String: String]?) -> String? {
        if let value = providerValue("Sportarr", in: providerIDs), canonical(value, prefix: "lg") != nil { return value.lowercased() }
        guard let value = providerValue("Tvdb", in: providerIDs), let number = Int64(value),
              (900_000_000 ..< 1_000_000_000).contains(number) else { return nil }
        return alias(number - 900_000_000, prefix: "lg")
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

    private static func providerValue(_ name: String, in ids: [String: String]?) -> String? {
        ids?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
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

//
//  UserEnteredURL.swift
//  Lume
//
//  An address typed into an add-playlist or edit form, made fetchable.
//
//  Users often type `example.com:8080` without a scheme. URLSession rejects
//  that with -1002 "unsupported URL" (`URLComponents` even reads `example.com`
//  as the scheme), and the error never says what's missing. IPTV panels and
//  LAN media servers are overwhelmingly plain http, which is also what every
//  placeholder in the form shows, so a schemeless address gets `http://`.
//

import Foundation

nonisolated enum UserEnteredURL {
    /// `input` trimmed, with `http://` in front when it names no scheme.
    /// Anything that already carries `://` (http, https, file, …) is left as
    /// typed, and an empty input stays empty.
    static func withDefaultScheme(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return trimmed }
        // A scheme with mangled slashes (`http:/host`, `https:host`): keep the
        // scheme the user meant instead of producing `http://http:/host`.
        let lowered = trimmed.lowercased()
        for scheme in ["https", "http"] where lowered.hasPrefix(scheme + ":") {
            let rest = trimmed.dropFirst(scheme.count + 1).drop { $0 == "/" }
            return "\(scheme)://\(rest)"
        }
        // Protocol-relative `//host`.
        let host = trimmed.drop { $0 == "/" }
        return "http://\(host)"
    }
}

//
//  LogRedaction.swift
//  Lume
//
//  Scrubs sensitive material out of strings that are interpolated into the
//  unified log with `privacy: .public` (and therefore end up verbatim in
//  user-exported diagnostic reports — see DebugLogExporter).
//
//  Playlist, EPG, and Stalker URLs carry account credentials: Xtream embeds
//  the username/password in the path or query, M3U links carry them as query
//  items, and Stalker portal links include the MAC address and short-lived
//  tokens. Any third-party message that echoes a URL (libvlc, FFmpeg,
//  CloudKit record dumps) must pass through here before going public.
//

import Foundation

nonisolated enum LogRedaction {
    /// Replaces every URL-like substring with `scheme://<redacted>`, keeping
    /// the surrounding message intact so the log line stays actionable.
    static func scrubURLs(in message: String) -> String {
        guard message.contains("://") else { return message }
        return message.replacing(urlPattern) { match in
            "\(match.output.scheme)://<redacted>"
        }
    }

    /// Compact, credential-free rendering of an error for public log
    /// interpolation: domain + code + scrubbed message. Never use
    /// `String(reflecting:)` on errors bound for public logs — CloudKit
    /// conflict errors can dump whole CKRecords, and synced-playlist records
    /// carry server URLs and account credentials.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(scrubURLs(in: nsError.localizedDescription))"
    }

    /// Matches `scheme://` followed by everything up to whitespace or a
    /// quote/bracket that commonly delimits URLs in log prose.
    private static let urlPattern = /(?<scheme>[A-Za-z][A-Za-z0-9+.\-]*):\/\/[^\s'"<>]+/
}

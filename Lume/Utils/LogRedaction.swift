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
//  items, Stalker portal links include the MAC address and short-lived
//  tokens, and a WebDAV share URL can carry `user:pass@` userinfo. Any
//  third-party message that echoes a URL (libvlc, FFmpeg, CloudKit record
//  dumps) must pass through here before going public.
//

import Foundation

nonisolated enum LogRedaction {
    /// Replaces every URL-like substring with `scheme://<redacted>` and every
    /// `Basic <token>` credential with `Basic <redacted>`, keeping the
    /// surrounding message intact so the log line stays actionable.
    ///
    /// The Basic pass lives here rather than behind its own entry point
    /// because `DebugLogExporter` funnels every exported line through this one
    /// function — a separate function would leave the export unprotected for
    /// any call site that forgot it.
    static func scrubURLs(in message: String) -> String {
        var scrubbed = message
        if scrubbed.contains("://") {
            scrubbed = scrubbed.replacing(urlPattern) { match in
                "\(match.output.scheme)://<redacted>"
            }
        }
        if scrubbed.contains("Basic ") {
            scrubbed = scrubbed.replacing(basicAuthPattern, with: "Basic <redacted>")
        }
        return scrubbed
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

    /// Matches the credential of an `Authorization: Basic <base64>` header
    /// value. The 8-character floor keeps ordinary prose ("Basic auth failed")
    /// readable; anything longer is redacted whether or not it decodes.
    private static let basicAuthPattern = /Basic\s+[A-Za-z0-9+\/=_\-]{8,}/
}

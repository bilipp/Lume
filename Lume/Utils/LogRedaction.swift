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
    ///
    /// Wrapped and underlying errors are followed (`networkError(URLError)`,
    /// `NSUnderlyingErrorKey`) and joined with `←`, because the outermost
    /// error is usually the least informative one: "Network error" says
    /// nothing, the `NSURLErrorDomain -1200` underneath says "TLS failed".
    static func describe(_ error: Error) -> String {
        var parts: [String] = []
        var current: Error? = error
        while let error = current, parts.count < maxErrorChain {
            parts.append(describeOne(error))
            current = underlying(of: error)
        }
        return parts.joined(separator: " ← ")
    }

    private static let maxErrorChain = 4

    private static func describeOne(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            return "DecodingError: \(summary(of: decoding))"
        }
        if let describing = error as? DiagnosticErrorDescribing {
            return "\(type(of: error)): \(describing.logDescription)"
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(scrubURLs(in: nsError.localizedDescription))"
    }

    /// The error one level down: an enum case's associated error
    /// (`XtreamError.networkError(_)`), else the Foundation underlying error.
    private static func underlying(of error: Error) -> Error? {
        if !(error is DecodingError) {
            for child in Mirror(reflecting: error).children {
                if let inner = child.value as? Error { return inner }
            }
        }
        return (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
    }

    /// Key names and indexes only, never values — a decoding context's debug
    /// description can quote the offending value, which may be a password.
    static func summary(of error: DecodingError) -> String {
        switch error {
        case let .dataCorrupted(context):
            context.codingPath.isEmpty ? "not valid JSON" : "corrupted value at \(path(context.codingPath))"
        case let .keyNotFound(key, context):
            "missing key '\(key.stringValue)' at \(path(context.codingPath))"
        case let .typeMismatch(type, context):
            "type mismatch: expected \(type) at \(path(context.codingPath))"
        case let .valueNotFound(type, context):
            "missing \(type) value at \(path(context.codingPath))"
        @unknown default:
            "undecodable"
        }
    }

    /// Renders a decoding path as e.g. `user_info.exp_date` or `[12].category_id`.
    static func path(_ codingPath: [any CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "response root" }
        var result = ""
        for key in codingPath {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return result
    }

    /// A short FNV-1a hash, stable across launches and devices (unlike
    /// `Hasher`), for correlating a value in a report without disclosing it.
    static func stableHash(_ value: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    /// Matches `scheme://` followed by everything up to whitespace or a
    /// quote/bracket that commonly delimits URLs in log prose.
    private static let urlPattern = /(?<scheme>[A-Za-z][A-Za-z0-9+.\-]*):\/\/[^\s'"<>]+/

    /// Matches the credential of an `Authorization: Basic <base64>` header
    /// value. The 8-character floor keeps ordinary prose ("Basic auth failed")
    /// readable; anything longer is redacted whether or not it decodes.
    private static let basicAuthPattern = /Basic\s+[A-Za-z0-9+\/=_\-]{8,}/
}

/// An error type with a hand-written, credential-free diagnostic summary.
/// `LogRedaction.describe(_:)` prefers it over `localizedDescription`, which
/// for most network errors embeds the failing URL.
nonisolated protocol DiagnosticErrorDescribing: Error {
    var logDescription: String { get }
}

nonisolated extension XtreamError: DiagnosticErrorDescribing {}
nonisolated extension M3UError: DiagnosticErrorDescribing {}
nonisolated extension StalkerError: DiagnosticErrorDescribing {}
nonisolated extension WebDAVError: DiagnosticErrorDescribing {}
nonisolated extension JellyfinError: DiagnosticErrorDescribing {}
nonisolated extension PlexError: DiagnosticErrorDescribing {}
nonisolated extension SiloError: DiagnosticErrorDescribing {}

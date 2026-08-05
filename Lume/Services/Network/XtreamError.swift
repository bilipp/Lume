//
//  XtreamError.swift
//  Lume
//
//  Errors surfaced by XtreamClient, plus the retry / logging policy attached
//  to each case.
//

import Foundation

enum XtreamError: LocalizedError {
    case invalidURL
    case authenticationFailed
    case networkError(Error)
    case decodingError(Error)
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The server URL is invalid."
        case .authenticationFailed:
            "Authentication failed. The provider rejected the request (this can also happen when the account's connection limit is reached)."
        case let .networkError(error):
            "Network error: \(error.localizedDescription)"
        case let .decodingError(error):
            "Failed to read the server response: \(error.localizedDescription)"
        case .invalidResponse:
            "Received an invalid response from the server."
        case let .serverError(code):
            "Server error (HTTP \(code))."
        }
    }

    /// Whether the failure is likely transient and worth retrying.
    /// Note: `authenticationFailed` (HTTP 401/403) is *not* retriable by
    /// default — for login it means bad credentials. During an
    /// already-authenticated sync it's usually the provider's connection /
    /// rate limit, so those call sites opt in via `retryAuthFailure`.
    var isRetriable: Bool {
        switch self {
        case .networkError:
            // Timeouts, connection reset (RST), lost connection — transient.
            true
        case let .serverError(code):
            code >= 500
        case .invalidURL, .authenticationFailed, .decodingError, .invalidResponse:
            false
        }
    }

    var isAuthFailure: Bool {
        if case .authenticationFailed = self { return true }
        return false
    }

    /// Credential-free summary for diagnostic logs. Interpolated with
    /// `privacy: .public` so user-exported logs stay actionable — which means
    /// it must never contain a URL: Xtream URLs carry the account username and
    /// password as query items, and underlying `NSError` descriptions can
    /// embed the failing URL.
    var logDescription: String {
        switch self {
        case .invalidURL:
            return "invalid server URL"
        case .authenticationFailed:
            return "HTTP 401/403 (bad credentials or connection limit)"
        case let .networkError(error):
            let nsError = error as NSError
            return "network error (\(nsError.domain) \(nsError.code))"
        case let .decodingError(error):
            switch error as? DecodingError {
            case .dataCorrupted:
                return "undecodable response (not valid JSON)"
            case let .keyNotFound(key, context):
                return "undecodable response (missing key '\(key.stringValue)' at \(Self.path(context.codingPath)))"
            case let .typeMismatch(type, context):
                return "undecodable response (type mismatch: expected \(type) at \(Self.path(context.codingPath)))"
            case let .valueNotFound(type, context):
                return "undecodable response (missing \(type) value at \(Self.path(context.codingPath)))"
            default:
                return "undecodable response"
            }
        case .invalidResponse:
            return "non-HTTP response"
        case let .serverError(code):
            return "HTTP \(code)"
        }
    }

    /// Renders a decoding path as e.g. `user_info.exp_date` or
    /// `[12].category_id` — key names and indexes only, never values, so it
    /// stays credential-free.
    private static func path(_ codingPath: [any CodingKey]) -> String {
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
}

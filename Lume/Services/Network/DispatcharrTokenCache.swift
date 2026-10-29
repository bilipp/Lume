//
//  DispatcharrTokenCache.swift
//  Lume
//
//  In-memory JWT sessions for Dispatcharr username/password sign-in, keyed by
//  server and credential. Tokens are never persisted: a relaunch signs in once
//  more. Dispatcharr throttles sign-in to 3 a minute, so concurrent callers
//  share one sign-in and a rejected or throttled one is remembered for a minute
//  instead of being retried by every poll.
//

import Foundation

actor DispatcharrTokenCache {
    static let shared = DispatcharrTokenCache()

    nonisolated struct Key: Hashable {
        /// Digest of server, username and password, so the cache holds no
        /// secret and a changed password never reuses the old session.
        let digest: String

        init(baseURL: URL, username: String, password: String) {
            digest = sha256Hex("\(baseURL.absoluteString)\n\(username)\n\(password)")
        }
    }

    nonisolated struct Session: Hashable {
        var access: String
        var accessExpiry: Date
        var refresh: String?
        var refreshExpiry: Date?

        func hasValidAccess(at now: Date, for validity: TimeInterval = DispatcharrTokenCache.expiryMargin) -> Bool {
            accessExpiry.timeIntervalSince(now) > validity
        }

        func hasValidRefresh(at now: Date) -> Bool {
            guard refresh != nil, let refreshExpiry else { return false }
            return refreshExpiry.timeIntervalSince(now) > DispatcharrTokenCache.expiryMargin
        }
    }

    /// Obtains a session given the previous one (to refresh from), or signs in.
    typealias Obtain = @Sendable (Session?) async throws(RecordingServerError) -> Session

    nonisolated static let expiryMargin: TimeInterval = 60
    nonisolated static let failureBackoff: TimeInterval = 60

    private nonisolated struct Failure {
        let error: RecordingServerError
        let until: Date
    }

    private var sessions: [Key: Session] = [:]
    private var inFlight: [Key: Task<Session, any Error>] = [:]
    private var failures: [Key: Failure] = [:]

    /// A session whose access token stays valid for at least `validity` past
    /// `now`, refreshing early otherwise — for a player that keeps sending the
    /// token for as long as it plays.
    func session(
        for key: Key,
        now: Date,
        validFor validity: TimeInterval,
        obtain: @escaping Obtain
    ) async throws(RecordingServerError) -> Session {
        if let session = sessions[key], session.hasValidAccess(at: now, for: max(validity, Self.expiryMargin)) {
            return session
        }
        if let failure = failures[key], failure.until > now {
            throw failure.error
        }
        if let task = inFlight[key] {
            return try await Self.value(of: task)
        }
        let previous = sessions[key]
        let task = Task<Session, any Error> { try await obtain(previous) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let session = try await Self.value(of: task)
            sessions[key] = session
            failures[key] = nil
            return session
        } catch {
            switch error {
            case .unauthorized, .rateLimited, .forbidden:
                sessions[key] = nil
                failures[key] = Failure(error: error, until: now.addingTimeInterval(Self.failureBackoff))
            default:
                break
            }
            throw error
        }
    }

    /// Drops `access` after the server rejected it, keeping the refresh token
    /// so the next call refreshes instead of signing in.
    func invalidate(_ key: Key, access: String) {
        guard var session = sessions[key], session.access == access else { return }
        session.accessExpiry = .distantPast
        sessions[key] = session
    }

    private static func value(of task: Task<Session, any Error>) async throws(RecordingServerError) -> Session {
        do {
            return try await task.value
        } catch {
            throw RecordingServerError(error)
        }
    }
}

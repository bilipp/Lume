//
//  PlaybackHealthTracker.swift
//  Lume
//
//  Did *this* playback session go well? `PlaybackQoE.shared.summary` cannot
//  answer that: it is a lifetime rolling aggregate, so `engineFallbacks > 0`
//  is true for practically every IPTV user within a week and reading it
//  directly would silence anything gated on it forever. So snapshot the
//  counters when the player opens, snapshot them again when it closes, and
//  judge the difference.
//
//  Reading the summary is free — no `persist()`, no timer, no per-tick write.
//  The whole cost of this file is two struct copies per player session.
//

import Foundation

// MARK: - Verdict

/// How the last full-screen playback session went. A plain value so the
/// App Store review shim can consume it without reaching into the player.
nonisolated enum PlaybackSessionHealth: Equatable {
    case healthy
    case unhealthy(Fault)
    /// The session produced no usable signal, which is not the same as a clean
    /// one — a naive diff of zeros reads as flawless.
    case notMeasured(Exclusion)

    /// Raw values are what a QA log prints.
    nonisolated enum Fault: String, Equatable {
        case engineFallback
        case startupFailure
        case rebuffering
    }

    nonisolated enum Exclusion: String, Equatable {
        /// Multi-View holds `PlaybackQoE.isSuspended` for its whole lifetime,
        /// so those sessions record nothing at all.
        case suspended
        /// Too little watch time for the rebuffer ratio to mean anything.
        case tooShort
    }

    /// The one state that may arm a review prompt.
    var isHealthy: Bool {
        self == .healthy
    }
}

// MARK: - Snapshot

/// The QoE counters that decide session health, summed across engines so an
/// in-session engine switch is still caught.
nonisolated struct PlaybackHealthSnapshot: Equatable {
    var engineFallbacks = 0
    var startupFailures = 0
    var rebufferSeconds: TimeInterval = 0
    var watchedSeconds: TimeInterval = 0

    init() {}

    init(_ summary: PlaybackQoESummary) {
        engineFallbacks = summary.engineFallbacks
        for stats in summary.engines.values {
            startupFailures += stats.startupFailures
            rebufferSeconds += stats.rebufferSeconds
            watchedSeconds += stats.watchedSeconds
        }
    }
}

nonisolated extension PlaybackSessionHealth {
    /// Fraction of the session that may be spent stalled. Five percent is the
    /// industry "poor" line — three seconds of buffering a minute, which the
    /// user certainly noticed. Judged per session, so one rough stream costs
    /// one prompt opportunity rather than all of them.
    static let rebufferRatioCeiling = 0.05

    /// Below this there is no meaningful ratio to take, and a session this
    /// short is not evidence the app is worth rating either way.
    static let minimumWatchedSeconds: TimeInterval = 60

    static func verdict(from start: PlaybackHealthSnapshot, to end: PlaybackHealthSnapshot) -> PlaybackSessionHealth {
        if end.engineFallbacks > start.engineFallbacks { return .unhealthy(.engineFallback) }
        if end.startupFailures > start.startupFailures { return .unhealthy(.startupFailure) }

        let watched = end.watchedSeconds - start.watchedSeconds
        guard watched >= minimumWatchedSeconds else { return .notMeasured(.tooShort) }

        let stalled = max(0, end.rebufferSeconds - start.rebufferSeconds)
        return stalled / watched > rebufferRatioCeiling ? .unhealthy(.rebuffering) : .healthy
    }
}

// MARK: - Tracker

/// Brackets full-screen playback sessions and judges how each one went.
///
/// The bracket is the *host* view's lifetime, not an engine's: it deliberately
/// spans startup retries, engine fallbacks and in-player episode swaps, which
/// is exactly the window whose health decides whether this was a good sitting.
/// Restarting it per title would hide a fallback the user just lived through.
///
/// Brackets are keyed by an opaque token rather than kept in a single slot,
/// because two players can be open at once — macOS gives the player its own
/// `WindowGroup(id: "player", for:)`, which opens a second window for a second
/// value, and iPadOS can run several scenes. A single slot let the second
/// player overwrite the first one's baseline, so the first was judged against
/// the wrong snapshot and the second silently inherited its verdict.
///
/// `MainActor`-isolated by project default, like `PlaybackQoE` itself.
final class PlaybackHealthTracker {
    static let shared = PlaybackHealthTracker()

    /// Identifies one open bracket. Opaque so a caller can only ever close the
    /// session it opened.
    nonisolated struct Token: Hashable {
        fileprivate let id = UUID()
    }

    /// One session's opening state. `opening` is `nil` when the session began
    /// while QoE was suspended and there was nothing to snapshot.
    private struct Bracket {
        var opening: PlaybackHealthSnapshot?
    }

    private var brackets: [Token: Bracket] = [:]

    /// The player opened. Call once per host view, not per engine attempt, and
    /// keep the token for the matching `endSession`.
    func beginSession() -> Token {
        let token = Token()
        let suspended = PlaybackQoE.shared.isSuspended
        brackets[token] = Bracket(opening: suspended ? nil : PlaybackHealthSnapshot(PlaybackQoE.shared.summary))
        return token
    }

    /// The player closed. Returns the verdict for that session, or `nil` when
    /// it produced no usable one.
    ///
    /// Must run *after* the engine views have torn down — `watchedSeconds` only
    /// lands in the summary in `PlaybackQoE.endSession()`, and the order of
    /// sibling `onDisappear` callbacks is undefined.
    ///
    /// With two players open the QoE summary is still app-wide, so each diff
    /// also picks up the other session's faults. That errs toward `.unhealthy`,
    /// which is the safe direction: it can cost a prompt, never earn a wrong one.
    func endSession(_ token: Token) -> PlaybackSessionHealth? {
        guard let bracket = brackets.removeValue(forKey: token) else { return nil }
        guard let opening = bracket.opening, !PlaybackQoE.shared.isSuspended else {
            return .notMeasured(.suspended)
        }
        return .verdict(from: opening, to: PlaybackHealthSnapshot(PlaybackQoE.shared.summary))
    }
}

//
//  PlaybackQoE.swift
//  Lume
//
//  Quality-of-experience accounting for playback — the metric set video
//  services actually measure, rather than CPU time:
//
//  * **Join time** (time-to-first-frame): playback requested → first frame
//    rendered, per engine. This is the number behind "streams take ages to
//    start".
//  * **Rebuffer ratio**: seconds stalled mid-stream over seconds watched.
//  * **Exit before video start**: sessions the user abandoned while still
//    spinning — the harshest signal that startup is too slow.
//  * **Startup failures / engine fallbacks**: how often the preferred engine
//    can't open a stream and hands off.
//
//  All four engines report into this one object at choke points they already
//  have (`hasStartedPlayback` flipping true, the startup watchdog arming), so
//  the numbers are directly comparable across KSPlayer, VLCKit, AVPlayer and
//  LumeEngine. It also emits the `PlayerStartup` signpost interval, which is
//  what `LumePerformanceTests` and Instruments read.
//
//  Counters are aggregated in memory and flushed to `UserDefaults` at session
//  boundaries only — never periodically. A recurring write during playback is
//  exactly what used to hitch KSPlayer every few seconds.
//

import Foundation
import OSLog

// MARK: - Persisted summary

/// Rolling per-engine startup statistics. Plain values, `nonisolated` so tests
/// and the debug screen can build and inspect one off the main actor.
nonisolated struct EngineQoEStats: Codable, Equatable {
    var sessions = 0
    var firstFrames = 0
    var joinTimeTotal: TimeInterval = 0
    var joinTimeWorst: TimeInterval = 0
    var lastJoinTime: TimeInterval = 0
    var startupFailures = 0
    var exitsBeforeVideoStart = 0
    var rebuffers = 0
    var rebufferSeconds: TimeInterval = 0
    /// Wall-clock seconds since the first frame, summed across sessions. The
    /// denominator for `rebufferRatio` — stall time included, matching how
    /// player analytics vendors report it.
    var watchedSeconds: TimeInterval = 0

    var meanJoinTime: TimeInterval {
        firstFrames > 0 ? joinTimeTotal / Double(firstFrames) : 0
    }

    /// Fraction of watch time spent stalled. `nil` until something was watched.
    var rebufferRatio: Double? {
        watchedSeconds > 0 ? rebufferSeconds / watchedSeconds : nil
    }
}

/// The whole QoE picture, keyed by `PlayerEngineKind.rawValue`.
nonisolated struct PlaybackQoESummary: Codable, Equatable {
    var engines: [String: EngineQoEStats] = [:]
    var engineFallbacks = 0
    var updatedAt: Date?

    var totalSessions: Int {
        engines.values.reduce(0) { $0 + $1.sessions }
    }
}

// MARK: - Tracker

/// Records QoE for the current playback session. `MainActor`-isolated (project
/// default) because every engine reports from the main thread.
@Observable
final class PlaybackQoE {
    static let shared = PlaybackQoE()

    /// Rolling totals, restored from `UserDefaults` at launch.
    private(set) var summary: PlaybackQoESummary

    private static let storageKey = "playbackQoESummary"

    // Current session
    private var engine: PlayerEngineKind?
    private var isLive = false
    private var startupBegan: Date?
    private var firstFrameAt: Date?
    private var stallBegan: Date?
    private var interval: PerfInterval?

    /// Internal rather than private so tests can build an instance backed by a
    /// scratch suite. Sharing `UserDefaults.standard` between a test and the
    /// singleton is a known source of cross-test flakiness in this project.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(PlaybackQoESummary.self, from: data)
        {
            summary = decoded
        } else {
            summary = PlaybackQoESummary()
        }
    }

    private let defaults: UserDefaults

    /// While set, every session hook below is a no-op. The summary models one
    /// stream at a time — join time, rebuffer ratio, exits before video start —
    /// so Multi-View, which runs up to four streams concurrently through the
    /// same coordinators, would fill it with meaningless numbers. Held for the
    /// lifetime of `MultiViewScreen` rather than checked at each call site.
    var isSuspended = false

    // MARK: - Session lifecycle

    /// A playback attempt has started: the engine has been handed a URL and the
    /// spinner is up. Opens the `PlayerStartup` interval.
    ///
    /// Safe to call again for a retry or a live-channel swap — the previous
    /// attempt is closed out first, so a zap counts as its own session.
    func beginStartup(engine: PlayerEngineKind, isLive: Bool) {
        guard !isSuspended else { return }
        if startupBegan != nil {
            endSession()
        }
        self.engine = engine
        self.isLive = isLive
        startupBegan = Date()
        firstFrameAt = nil
        stallBegan = nil
        interval = Perf.begin(.playerStartup)
        mutate(engine) { $0.sessions += 1 }
    }

    /// The first frame is on screen. Closes the startup interval and records
    /// join time. Idempotent within a session.
    func noteFirstFrame() {
        guard !isSuspended, let startupBegan, firstFrameAt == nil, let engine else { return }
        let now = Date()
        let joinTime = now.timeIntervalSince(startupBegan)
        firstFrameAt = now
        if let interval {
            Perf.end(interval)
            self.interval = nil
        }
        mutate(engine) {
            $0.firstFrames += 1
            $0.joinTimeTotal += joinTime
            $0.lastJoinTime = joinTime
            $0.joinTimeWorst = max($0.joinTimeWorst, joinTime)
        }
        let name = engine.rawValue
        let live = isLive
        Logger.performance.log(
            "join time \(joinTime, format: .fixed(precision: 2), privacy: .public)s engine=\(name, privacy: .public) live=\(live, privacy: .public)"
        )
        persist()
    }

    /// A mid-stream stall began (startup buffering doesn't count — that's join
    /// time). No-op before the first frame or while already stalled.
    func noteStallBegan() {
        guard !isSuspended, firstFrameAt != nil, stallBegan == nil else { return }
        stallBegan = Date()
        Perf.event(.playerRebuffer)
    }

    /// The stall cleared. Adds its duration to the rebuffer total.
    func noteStallEnded() {
        guard !isSuspended, let stallBegan, let engine else { return }
        let seconds = Date().timeIntervalSince(stallBegan)
        self.stallBegan = nil
        mutate(engine) {
            $0.rebuffers += 1
            $0.rebufferSeconds += seconds
        }
        persist()
    }

    /// The engine gave up before producing a frame.
    func noteStartupFailure() {
        guard !isSuspended, let engine else { return }
        Perf.event(.playerStartupFailure)
        mutate(engine) { $0.startupFailures += 1 }
        persist()
    }

    /// The host is switching to the next engine in the priority list.
    func noteEngineFallback(to next: PlayerEngineKind) {
        guard !isSuspended else { return }
        Perf.event(.playerEngineFallback)
        summary.engineFallbacks += 1
        let previous = engine?.rawValue ?? "none"
        let replacement = next.rawValue
        Logger.performance.log(
            "engine fallback \(previous, privacy: .public) -> \(replacement, privacy: .public)"
        )
        persist()
    }

    /// Playback ended (view torn down, channel closed, app backgrounded). Closes
    /// any open interval and — if no frame ever arrived — counts an exit before
    /// video start.
    func endSession() {
        guard !isSuspended, let engine, let startupBegan else { return }
        if let interval {
            Perf.end(interval)
            self.interval = nil
        }
        if let stallBegan {
            let seconds = Date().timeIntervalSince(stallBegan)
            mutate(engine) {
                $0.rebuffers += 1
                $0.rebufferSeconds += seconds
            }
        }
        if let firstFrameAt {
            let watched = Date().timeIntervalSince(firstFrameAt)
            mutate(engine) { $0.watchedSeconds += watched }
        } else {
            let waited = Date().timeIntervalSince(startupBegan)
            mutate(engine) { $0.exitsBeforeVideoStart += 1 }
            let name = engine.rawValue
            Logger.performance.log(
                "exit before video start after \(waited, format: .fixed(precision: 1), privacy: .public)s engine=\(name, privacy: .public)"
            )
        }
        self.engine = nil
        self.startupBegan = nil
        firstFrameAt = nil
        stallBegan = nil
        persist()
    }

    // MARK: - Maintenance

    /// Clears every counter (debug screen "Reset statistics").
    func reset() {
        summary = PlaybackQoESummary()
        persist()
    }

    // MARK: - Private

    private func mutate(_ engine: PlayerEngineKind, _ body: (inout EngineQoEStats) -> Void) {
        var stats = summary.engines[engine.rawValue] ?? EngineQoEStats()
        body(&stats)
        summary.engines[engine.rawValue] = stats
    }

    /// Flushed only at boundaries — first frame, stall end, session end — never
    /// on a timer, so playback is never interrupted by our own bookkeeping.
    private func persist() {
        summary.updatedAt = Date()
        guard let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

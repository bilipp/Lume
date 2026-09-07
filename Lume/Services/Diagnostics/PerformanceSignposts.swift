//
//  PerformanceSignposts.swift
//  Lume
//
//  The one place app-defined performance milestones are named.
//
//  Every phase we have ever had to profile by hand (playlist sync, EPG ingest,
//  guide window loads, time-to-first-frame) emits an `OSSignposter` interval
//  from here. That single instrumentation buys three things:
//
//  1. A Points of Interest lane in Instruments, so a device trace shows the
//     phase boundaries instead of an undifferentiated wall of stack samples.
//  2. `XCTOSSignpostMetric` assertions in `LumePerformanceTests`, so a phase
//     getting slower is a test failure rather than a customer complaint.
//  3. Free `os_log`-based timing in the field, readable via the debug log
//     exporter without attaching a debugger.
//
//  The names below are a contract with the performance tests — renaming one
//  silently detaches its benchmark, so change `Name` and the test together.
//

import Foundation
import OSLog

// MARK: - Signpost names

/// A named performance milestone.
///
/// `OSSignposter` requires a `StaticString` name, while `XCTOSSignpostMetric`
/// needs the same text as a `String`; wrapping the literal once keeps the two
/// from drifting apart.
nonisolated struct PerfSignpost {
    let name: StaticString

    init(_ name: StaticString) {
        self.name = name
    }

    /// The same name as a `String`, for `XCTOSSignpostMetric(subsystem:category:name:)`.
    var metricName: String {
        name.description
    }
}

nonisolated extension PerfSignpost {
    // Content sync
    static let playlistSync = PerfSignpost("PlaylistSync")
    static let syncCategories = PerfSignpost("SyncCategories")
    static let syncMovies = PerfSignpost("SyncMovies")
    static let syncSeries = PerfSignpost("SyncSeries")
    static let syncLiveStreams = PerfSignpost("SyncLiveStreams")

    // Content sync sub-phases. Nested inside the SyncMovies/SyncSeries/
    // SyncLiveStreams intervals above, which stay as the outer boundary so
    // existing traces and benchmark baselines keep resolving.
    static let xtreamFetchMovies = PerfSignpost("XtreamFetchMovies")
    static let xtreamDecodeMovies = PerfSignpost("XtreamDecodeMovies")
    static let upsertMovies = PerfSignpost("UpsertMovies")
    static let pruneMovies = PerfSignpost("PruneMovies")
    static let xtreamFetchSeries = PerfSignpost("XtreamFetchSeries")
    static let xtreamDecodeSeries = PerfSignpost("XtreamDecodeSeries")
    static let upsertSeries = PerfSignpost("UpsertSeries")
    static let pruneSeries = PerfSignpost("PruneSeries")
    static let xtreamFetchLiveStreams = PerfSignpost("XtreamFetchLiveStreams")
    static let xtreamDecodeLiveStreams = PerfSignpost("XtreamDecodeLiveStreams")
    static let upsertLiveStreams = PerfSignpost("UpsertLiveStreams")
    static let pruneLiveStreams = PerfSignpost("PruneLiveStreams")

    /// Only emitted when the sync actually has to wait between content phases
    /// to respect a provider's one-connection cap — its absence in a trace is
    /// the signal that the spacing cost nothing.
    static let xtreamPhaseSpacing = PerfSignpost("XtreamPhaseSpacing")

    static let m3uDownload = PerfSignpost("M3UDownload")
    static let m3uImport = PerfSignpost("M3UImport")

    // M3U import sub-phases. Nested inside the M3UImport interval above, which
    // stays as the outer boundary so existing traces and benchmark baselines
    // keep resolving.
    /// Emitted once per *gap between batches*, not once per import: parsing and
    /// importing interleave, so a provider file produces ~860 short intervals
    /// whose union is the scan time. A trace or `XCTOSSignpostMetric` expecting
    /// one interval per import will not find one — sum them instead.
    static let m3uParse = PerfSignpost("M3UParse")
    static let m3uClassify = PerfSignpost("M3UClassify")
    static let m3uUpsertLive = PerfSignpost("M3UUpsertLive")
    static let m3uUpsertMovies = PerfSignpost("M3UUpsertMovies")
    static let m3uUpsertEpisodes = PerfSignpost("M3UUpsertEpisodes")
    static let m3uPruneLive = PerfSignpost("M3UPruneLive")
    static let m3uPruneMovies = PerfSignpost("M3UPruneMovies")
    static let m3uPruneEpisodes = PerfSignpost("M3UPruneEpisodes")
    static let m3uPruneSeries = PerfSignpost("M3UPruneSeries")
    static let m3uPruneCategories = PerfSignpost("M3UPruneCategories")

    // EPG
    static let epgSourceSync = PerfSignpost("EPGSourceSync")
    static let epgIngest = PerfSignpost("EPGIngest")
    static let channelEPGLoad = PerfSignpost("ChannelEPGLoad")
    static let guideWindowLoad = PerfSignpost("GuideWindowLoad")

    // Home
    static let homeTrendingLoad = PerfSignpost("HomeTrendingLoad")
    static let homeRecommendations = PerfSignpost("HomeRecommendations")

    // Player
    static let playerStartup = PerfSignpost("PlayerStartup")
    static let playerRebuffer = PerfSignpost("PlayerRebuffer")
    static let playerEngineFallback = PerfSignpost("PlayerEngineFallback")
    static let playerStartupFailure = PerfSignpost("PlayerStartupFailure")
}

// MARK: - Interval handle

/// An in-flight signpost interval. Opaque on purpose: callers either use
/// `Perf.measure` or pair `Perf.begin`/`Perf.end` in a `defer`.
nonisolated struct PerfInterval {
    fileprivate let signpost: PerfSignpost
    fileprivate let state: OSSignpostIntervalState
}

// MARK: - Facade

/// Emits the app's performance signposts.
///
/// `nonisolated` throughout because the hottest call sites — the streaming
/// parsers and the off-main EPG loaders — are themselves `nonisolated`.
/// `OSSignposter` no-ops cheaply when nothing is recording, so these calls are
/// safe to leave in shipping builds (and are what makes a field trace useful).
nonisolated enum Perf {
    /// Matches `Logger`'s subsystem so a single Instruments/`log` filter covers
    /// both the app's log messages and its signposts.
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.bilipp.lume"
    static let category = "Performance"

    private static let signposter = OSSignposter(subsystem: subsystem, category: category)

    /// Whether anything is currently recording signposts. Worth checking before
    /// building an expensive interval message, not before the interval itself.
    static var isEnabled: Bool {
        signposter.isEnabled
    }

    static func begin(_ signpost: PerfSignpost) -> PerfInterval {
        let state = signposter.beginInterval(signpost.name, id: signposter.makeSignpostID())
        return PerfInterval(signpost: signpost, state: state)
    }

    static func end(_ interval: PerfInterval) {
        signposter.endInterval(interval.signpost.name, interval.state)
    }

    /// Emit a zero-length event — for things that happen rather than take time
    /// (a rebuffer starting, an engine handing off).
    static func event(_ signpost: PerfSignpost) {
        signposter.emitEvent(signpost.name)
    }

    /// Wrap a synchronous phase.
    static func measure<T>(_ signpost: PerfSignpost, _ body: () throws -> T) rethrows -> T {
        let interval = begin(signpost)
        defer { end(interval) }
        return try body()
    }

    /// Wrap an asynchronous phase. The interval state never leaves the caller's
    /// isolation domain, so it may safely live across the `await`.
    static func measure<T>(_ signpost: PerfSignpost, _ body: () async throws -> T) async rethrows -> T {
        let interval = begin(signpost)
        defer { end(interval) }
        return try await body()
    }
}

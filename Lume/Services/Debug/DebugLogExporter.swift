//
//  DebugLogExporter.swift
//  Lume
//
//  Builds a shareable diagnostic report from the app's own unified-log output.
//  Everything Lume logs through `Logger` (see Utils/Logger.swift) is already
//  captured by the OS; this reads it back for the current process, scoped to the
//  debugging session, prepends a device/app header, and writes it to a temp file
//  the user can email to support or share.
//
//  Interpolated values stay `<private>`-redacted (the default) — the report
//  carries the log messages and app/device context needed to triage a problem
//  without leaking playlist URLs, credentials, or other personal data.
//
//  Metadata is gathered on the main actor (it reads MainActor-isolated player
//  settings); the OSLogStore read is `async nonisolated`, so it runs off the
//  main actor and never stalls the UI.
//

import Foundation
import OSLog

nonisolated struct DebugLogExporter {
    /// App / device context, gathered once on the main actor via `currentMetadata()`.
    struct Metadata {
        var appVersion: String
        var buildNumber: String
        var platform: String
        var osVersion: String
        var deviceModel: String
        var engineSummary: String
        /// Per-engine playback QoE lines (join time, rebuffering, failures).
        /// Pre-rendered because `PlaybackQoE` is MainActor-isolated.
        var playbackQoE: [String] = []
        /// The newest MetricKit payload summary, when one has been delivered.
        var fieldMetrics: [String] = []
    }

    /// Oldest entries to include when the session start is unknown or very old.
    private static let maxLookback: TimeInterval = 24 * 60 * 60

    let metadata: Metadata

    enum ExportError: Error {
        case storeUnavailable
    }

    /// The report as plain text: a metadata header followed by the log entries.
    /// Reads the unified log off the main actor.
    func makeReport(now: Date = Date()) async throws -> String {
        var lines = header(now: now)
        lines.append(contentsOf: performanceSection())
        let entries = try collectEntries(now: now)
        lines.append("")
        lines.append("--- Log entries (\(entries.count)) ---")
        if entries.isEmpty {
            lines.append("No log entries were captured for this session. Reproduce the problem while Debug Logging is on, then export again.")
        } else {
            lines.append(contentsOf: entries)
        }
        return lines.joined(separator: "\n")
    }

    /// Writes `makeReport()` to a temp `.txt` file and returns its URL for
    /// sharing / mail attachment. The filename carries the date so a support
    /// inbox can tell submissions apart.
    func writeReport(now: Date = Date()) async throws -> URL {
        let report = try await makeReport(now: now)
        let name = "Lume-Diagnostics-\(Self.fileStamp.string(from: now)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try report.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Log collection

    private func collectEntries(now: Date) throws -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
            throw ExportError.storeUnavailable
        }
        let start = startDate(now: now)
        let position = store.position(date: start)
        let predicate = Bundle.main.bundleIdentifier.map {
            NSPredicate(format: "subsystem == %@", $0)
        }

        let entries = try store.getEntries(at: position, matching: predicate)
        return entries.compactMap { entry -> String? in
            switch entry {
            case let log as OSLogEntryLog:
                let time = Self.entryStamp.string(from: log.date)
                // Last line of defense: even if a future call site accidentally
                // interpolates a URL with `privacy: .public`, it must not reach
                // a shared report — stream URLs carry playlist credentials.
                let message = LogRedaction.scrubURLs(in: log.composedMessage)
                return "\(time)  [\(log.category)] \(Self.label(for: log.level))  \(message)"
            case let signpost as OSLogEntrySignpost:
                // MetricKit is compiled out on tvOS, so on Apple TV the `Perf`
                // intervals are the only phase timing a field report can carry.
                let time = Self.entryStamp.string(from: signpost.date)
                let message = LogRedaction.scrubURLs(in: signpost.composedMessage)
                let head = "\(time)  [\(signpost.category)] \(Self.signpostLabel(for: signpost.signpostType))  \(signpost.signpostName) #\(signpost.signpostIdentifier)"
                return message.isEmpty ? head : "\(head)  \(message)"
            default:
                return nil
            }
        }
    }

    /// The debugging session start, floored to `maxLookback` so an ancient
    /// session (logging left on for days) doesn't drag in an unbounded history.
    private func startDate(now: Date) -> Date {
        let floor = now.addingTimeInterval(-Self.maxLookback)
        guard let since = DebugLogSettings.enabledSince else { return floor }
        return max(since, floor)
    }

    // MARK: - Header

    func header(now: Date) -> [String] {
        [
            "Lume Diagnostic Log",
            "===================",
            "App: Lume \(metadata.appVersion) (build \(metadata.buildNumber))",
            "Platform: \(metadata.platform) \(metadata.osVersion)",
            "Device: \(metadata.deviceModel)",
            "Player engines: \(metadata.engineSummary)",
            "Generated: \(Self.entryStamp.string(from: now))",
            "Session started: \(DebugLogSettings.enabledSince.map { Self.entryStamp.string(from: $0) } ?? "unknown")"
        ]
    }

    // MARK: - Performance section

    /// Playback QoE and field metrics, when there is anything to report. These
    /// numbers turn "streams are slow to start" into an actual measurement, so
    /// they belong in the report a user sends rather than in a localized screen.
    func performanceSection() -> [String] {
        var lines: [String] = []
        if !metadata.playbackQoE.isEmpty {
            lines.append("")
            lines.append("--- Playback quality of experience ---")
            lines.append(contentsOf: metadata.playbackQoE)
        }
        if !metadata.fieldMetrics.isEmpty {
            lines.append("")
            lines.append("--- Latest MetricKit payload ---")
            lines.append(contentsOf: metadata.fieldMetrics)
        }
        return lines
    }

    /// Renders one line per engine that has seen a playback attempt.
    static func qoeLines(_ summary: PlaybackQoESummary) -> [String] {
        guard summary.totalSessions > 0 else { return [] }
        var lines: [String] = []
        for kind in PlayerEngineKind.allCases {
            guard let stats = summary.engines[kind.rawValue], stats.sessions > 0 else { continue }
            var parts = [
                "sessions=\(stats.sessions)",
                "firstFrames=\(stats.firstFrames)",
                "meanJoin=\(String(format: "%.2f", stats.meanJoinTime))s",
                "worstJoin=\(String(format: "%.2f", stats.joinTimeWorst))s",
                "rebuffers=\(stats.rebuffers)"
            ]
            if let ratio = stats.rebufferRatio {
                parts.append("rebufferRatio=\(String(format: "%.4f", ratio))")
            }
            if stats.startupFailures > 0 {
                parts.append("startupFailures=\(stats.startupFailures)")
            }
            if stats.exitsBeforeVideoStart > 0 {
                parts.append("exitsBeforeVideoStart=\(stats.exitsBeforeVideoStart)")
            }
            lines.append("\(kind.displayName): \(parts.joined(separator: " "))")
        }
        if summary.engineFallbacks > 0 {
            lines.append("Engine fallbacks: \(summary.engineFallbacks)")
        }
        return lines
    }

    // MARK: - Metadata

    /// Gather app / device context. Runs on the main actor because it reads the
    /// MainActor-isolated player-engine settings.
    @MainActor
    static func currentMetadata() -> Metadata {
        let defaults = UserDefaults.standard
        let priorityRaw = defaults.string(forKey: PlayerSettings.enginePriorityKey) ?? ""
        let legacyRaw = defaults.string(forKey: PlayerSettings.engineKey) ?? PlayerEngineKind.defaultValue.rawValue
        let engineSummary = PlayerEnginePriority.resolve(priorityRaw: priorityRaw, legacyEngineRaw: legacyRaw)
            .map(\.displayName)
            .joined(separator: " › ")

        #if canImport(MetricKit) && !os(tvOS)
            let fieldMetrics = AppPerformanceMetrics.shared.latestSummary
        #else
            let fieldMetrics: [String] = []
        #endif

        return Metadata(
            appVersion: SupportInfo.appVersion,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
            platform: platformName,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: deviceModel,
            engineSummary: engineSummary,
            playbackQoE: qoeLines(PlaybackQoE.shared.summary),
            fieldMetrics: fieldMetrics
        )
    }

    static var platformName: String {
        #if os(tvOS)
            "tvOS"
        #elseif os(macOS)
            "macOS"
        #elseif os(visionOS)
            "visionOS"
        #else
            "iOS"
        #endif
    }

    /// The hardware model identifier (e.g. "iPhone17,1"), read from `utsname`.
    /// Assembled scalar-by-scalar to avoid `String(decoding:)`, which lint bans.
    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    static func signpostLabel(for type: OSLogEntrySignpost.SignpostType) -> String {
        switch type {
        case .intervalBegin: "signpost-begin"
        case .intervalEnd: "signpost-end"
        case .event: "signpost-event"
        case .undefined: "signpost"
        @unknown default: "signpost"
        }
    }

    static func label(for level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        case .undefined: "—"
        @unknown default: "—"
        }
    }

    // MARK: - Formatters

    private static let entryStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}

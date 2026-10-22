//
//  DebugLogExporter.swift
//  Lume
//
//  Builds the shareable diagnostic report: a context header (app, device,
//  network, playlists, settings, sync), a digest of recent problems and
//  sessions, the performance counters, and the full `DiagnosticJournal` — the
//  persistent log that survives relaunches and crashes, so a report can be
//  sent *after* something went wrong without having turned anything on first.
//
//  Nothing personal leaves the device: playlist names, hosts, usernames,
//  passwords and MACs are never written; addresses appear only as their shape
//  (`NetworkDiagnostics.shape`); every log line was redacted when it was
//  recorded. The user can read the whole report before sending it.
//
//  Metadata is gathered on the main actor (it reads MainActor-isolated
//  settings and services); everything else — the catalog counts, the network
//  path, the journal read — runs off it, so preparing a report never stalls
//  the UI, even over a 600k-row catalog.
//

import Foundation
import OSLog
import SwiftData

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
        var installSource = ""
        var locale = ""
        var sessionStartedAt: Date?
        var launchCount = 0
        var lastUnexpectedEnd: Date?
        var isPremium: Bool?
        var cloudSync: [String] = []
        var settings: [String] = []
        /// Where the user opened diagnostics from ("Add Playlist") and the
        /// error that screen was showing, so the report leads with it.
        var origin: String?
        var visibleProblem: String?
        var userNote: String?
    }

    let metadata: Metadata
    /// The catalog container, for the playlist / content summary. `nil` skips it.
    var container: ModelContainer?
    var journal: DiagnosticJournal = .shared

    /// How far back "Recent problems" looks.
    static let problemWindow: TimeInterval = 7 * 24 * 60 * 60
    private static let maxProblems = 40
    private static let maxSignposts = 400
    /// The newest MetricKit diagnostic payload (crash / hang call stacks) rides
    /// along in full when it's this small — symbolicated later against the dSYM.
    private static let maxDiagnosticPayloadBytes = 256 * 1024

    enum ExportError: Error {
        case storeUnavailable
    }

    // MARK: - Report

    /// The report as plain text. Runs off the main actor.
    func makeReport(now: Date = Date()) async -> String {
        let journalText = journal.contents()
        let networkPath = await DeviceDiagnostics.networkPathDescription()

        var lines = header(now: now)
        lines += section("Device", deviceLines(networkPath: networkPath))
        if let container {
            lines += section("Playlists", Self.catalogLines(container: container, now: now))
        }
        lines += section("Sync", metadata.cloudSync)
        lines += section("Settings", metadata.settings)
        lines += section("Recent problems (last 7 days, newest first)", Self.problemDigest(journalText, now: now))
        lines += section("Sessions (newest first)", Self.sessionDigest(journalText))
        lines += performanceSection()
        lines += section("Latest MetricKit diagnostics", Self.diagnosticPayloadLines())

        let journalLines = journalText.split(separator: "\n", omittingEmptySubsequences: true)
        lines.append("")
        lines.append("--- Log (\(journalLines.count) entries, oldest first) ---")
        if journalLines.isEmpty {
            lines.append("The log is empty — it starts recording from the first launch of this version.")
        } else {
            lines.append(contentsOf: journalLines.map(String.init))
        }

        let signposts = collectSignposts(now: now)
        if !signposts.isEmpty {
            lines.append("")
            lines.append("--- Performance signposts (this launch, last \(signposts.count)) ---")
            lines.append(contentsOf: signposts)
        }
        return lines.joined(separator: "\n")
    }

    /// Writes `makeReport()` to a temp `.txt` file and returns its URL for
    /// sharing / mail attachment. The filename carries the date so a support
    /// inbox can tell submissions apart.
    func writeReport(now: Date = Date()) async throws -> URL {
        let report = await makeReport(now: now)
        let name = "Lume-Diagnostics-\(DiagnosticDateFormat.file.string(from: now)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try report.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A few hundred characters that fit a `mailto:` QR code — for Apple TV,
    /// which can neither attach a file nor compose mail.
    func compactSummary(now: Date = Date(), maxLength: Int = 900) -> String {
        let journalText = journal.contents()
        var lines = [
            "Lume \(metadata.appVersion) (\(metadata.buildNumber)) \(metadata.installSource)",
            "\(metadata.platform) \(metadata.osVersion) · \(metadata.deviceModel)"
        ]
        if let origin = metadata.origin { lines.append("From: \(origin)") }
        if let problem = metadata.visibleProblem { lines.append("Shown: \(LogRedaction.scrubURLs(in: problem))") }
        if let container {
            lines += Self.catalogLines(container: container, now: now, compact: true)
        }
        lines.append("Recent problems:")
        let problems = Self.problemDigest(journalText, now: now, compact: true)
        lines += problems.isEmpty ? ["none"] : problems

        var summary = ""
        for line in lines {
            let candidate = summary.isEmpty ? line : summary + "\n" + line
            guard candidate.count <= maxLength else { break }
            summary = candidate
        }
        return summary
    }

    // MARK: - Header

    func header(now: Date) -> [String] {
        var lines = [
            "Lume Diagnostic Report",
            "======================"
        ]
        if let origin = metadata.origin {
            lines.append("Reported from: \(origin)")
        }
        if let problem = metadata.visibleProblem, !problem.isEmpty {
            lines.append("Error on screen: \(LogRedaction.scrubURLs(in: problem))")
        }
        if let note = metadata.userNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            lines.append("User's description: \(LogRedaction.scrubURLs(in: note))")
        }
        lines += [
            "App: Lume \(metadata.appVersion) (build \(metadata.buildNumber))\(metadata.installSource.isEmpty ? "" : " · \(metadata.installSource)")",
            "Platform: \(metadata.platform) \(metadata.osVersion)",
            "Device: \(metadata.deviceModel)",
            "Player engines: \(metadata.engineSummary)"
        ]
        if let isPremium = metadata.isPremium {
            lines.append("Lume Pro: \(isPremium ? "yes" : "no")")
        }
        if !metadata.locale.isEmpty {
            lines.append("Locale: \(metadata.locale)")
        }
        lines.append("Generated: \(DiagnosticDateFormat.entry.string(from: now))")
        if let started = metadata.sessionStartedAt {
            lines.append("This session: launch #\(metadata.launchCount), up \(DeviceDiagnostics.uptimeDescription(since: started, now: now))")
        }
        if let crash = metadata.lastUnexpectedEnd {
            lines.append("Last unexpected end: \(DiagnosticDateFormat.entry.string(from: crash))")
        }
        return lines
    }

    private func deviceLines(networkPath: String) -> [String] {
        [
            "Network: \(networkPath)",
            "Storage: \(DeviceDiagnostics.freeDiskDescription)",
            "Memory: \(DeviceDiagnostics.memoryDescription)",
            "Power: \(DeviceDiagnostics.powerDescription)"
        ]
    }

    private func section(_ title: String, _ body: [String]) -> [String] {
        guard !body.isEmpty else { return [] }
        return ["", "--- \(title) ---"] + body
    }

    // MARK: - Digests

    /// Warnings and worse from the last week, deduplicated (numbers collapsed
    /// so "retry 1/2" and "retry 2/2" count as one) with a count and last-seen.
    static func problemDigest(_ journal: String, now: Date, compact: Bool = false) -> [String] {
        struct Problem {
            var sample: String
            var count: Int
            var last: Date
        }
        var problems: [String: Problem] = [:]
        let cutoff = now.addingTimeInterval(-problemWindow)
        for line in journal.split(separator: "\n") {
            guard let entry = DiagnosticJournal.parse(line), entry.level.isProblem, entry.date >= cutoff else { continue }
            let text = "[\(entry.category)] \(entry.level.rawValue): \(entry.message)"
            let key = text.replacing(/\d+(\.\d+)?/, with: "#")
            if var existing = problems[key] {
                existing.count += 1
                existing.last = max(existing.last, entry.date)
                existing.sample = text
                problems[key] = existing
            } else {
                problems[key] = Problem(sample: text, count: 1, last: entry.date)
            }
        }
        let limit = compact ? 6 : maxProblems
        return problems.values.sorted { $0.last > $1.last }.prefix(limit).map { problem in
            let count = problem.count > 1 ? " ×\(problem.count)" : ""
            if compact {
                return "• \(String(problem.sample.prefix(140)))\(count)"
            }
            return "\(DiagnosticDateFormat.entry.string(from: problem.last))\(count)  \(problem.sample)"
        }
    }

    /// Session starts and unexpected ends, so the timeline is readable at a glance.
    static func sessionDigest(_ journal: String) -> [String] {
        let markers = journal.split(separator: "\n").compactMap { line -> String? in
            guard let entry = DiagnosticJournal.parse(line), entry.category == "App" else { return nil }
            guard entry.message.hasPrefix("Session started") || entry.message.hasPrefix("Previous session ended") else {
                return nil
            }
            return "\(DiagnosticDateFormat.entry.string(from: entry.date))  \(entry.message)"
        }
        return Array(markers.suffix(12).reversed())
    }

    // MARK: - Performance section

    /// Playback QoE and field metrics, when there is anything to report. These
    /// numbers turn "streams are slow to start" into an actual measurement.
    func performanceSection() -> [String] {
        section("Playback quality of experience", metadata.playbackQoE)
            + section("Latest MetricKit payload", metadata.fieldMetrics)
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

    /// The newest archived MetricKit diagnostic payload (crashes, hangs, disk
    /// write exceptions), verbatim when small enough. Its call stacks are raw
    /// addresses, so it carries no user data — and it's the only crash record
    /// a user can hand over without a Mac.
    static func diagnosticPayloadLines() -> [String] {
        #if canImport(MetricKit) && !os(tvOS)
            guard let directory = AppPerformanceMetrics.archiveDirectory,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
                  )
            else { return [] }
            let newest = files
                .filter { $0.lastPathComponent.hasPrefix("diagnostics-") }
                .max { lhs, rhs in
                    let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return left < right
                }
            guard let newest, let data = FileManager.default.contents(atPath: newest.path),
                  let json = String(bytes: data, encoding: .utf8)
            else { return [] }
            guard data.count <= maxDiagnosticPayloadBytes else {
                return ["\(newest.lastPathComponent): \(DeviceDiagnostics.byteString(Int64(data.count))) — too large to include"]
            }
            return ["\(newest.lastPathComponent):", json]
        #else
            return []
        #endif
    }

    // MARK: - Signposts

    /// `Perf` intervals from this launch, read back from the unified log. On
    /// Apple TV (no MetricKit) they are the only phase timing a report carries.
    private func collectSignposts(now: Date) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let position = store.position(date: now.addingTimeInterval(-24 * 60 * 60))
        let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", Perf.subsystem, Perf.category)
        guard let entries = try? store.getEntries(at: position, matching: predicate) else { return [] }
        var lines: [String] = []
        for case let signpost as OSLogEntrySignpost in entries {
            let time = DiagnosticDateFormat.entry.string(from: signpost.date)
            let message = LogRedaction.scrubURLs(in: signpost.composedMessage)
            let head = "\(time)  \(Self.signpostLabel(for: signpost.signpostType))  \(signpost.signpostName) #\(signpost.signpostIdentifier)"
            lines.append(message.isEmpty ? head : "\(head)  \(message)")
        }
        return Array(lines.suffix(Self.maxSignposts))
    }

    // MARK: - Metadata

    /// Gather app / device context. Runs on the main actor because it reads
    /// MainActor-isolated settings and services.
    @MainActor
    static func currentMetadata(
        cloudSync: CloudSyncCoordinator? = nil,
        origin: String? = nil,
        visibleProblem: String? = nil,
        userNote: String? = nil
    ) -> Metadata {
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
            fieldMetrics: fieldMetrics,
            installSource: DeviceDiagnostics.installSource,
            locale: DeviceDiagnostics.localeSummary,
            sessionStartedAt: DiagnosticSession.startedAt,
            launchCount: DiagnosticSession.launchCount,
            lastUnexpectedEnd: DiagnosticSession.lastUnexpectedEnd,
            isPremium: PremiumManager.shared.isPremium,
            cloudSync: cloudSync.map { cloudSyncLines($0.status) } ?? [],
            settings: settingsLines(defaults),
            origin: origin,
            visibleProblem: visibleProblem,
            userNote: userNote
        )
    }

    /// Backend, state, last sync and last error. The status carries no
    /// account or device id, key, pairing code or payload, and a custom Lume
    /// Cloud server appears only as its kind, never its address.
    @MainActor
    static func cloudSyncLines(
        _ status: CloudSyncStatus,
        lumeCloudServer: LumeCloudConfig.ServerKind = LumeCloudConfig.serverKind
    ) -> [String] {
        var lines: [String] = []
        switch status.backend {
        case .icloud:
            lines.append("Backend: iCloud")
            lines.append("Account: \(status.account) · syncing: \(status.isSyncing ? "yes" : "no")")
        case .lumecloud:
            lines.append("Backend: Lume Cloud · server: \(lumeCloudServer.rawValue)")
            lines.append("State: \(lumeCloudStateLabel(status.lumeCloud))")
        case .off:
            lines.append("Backend: off")
        }
        lines.append("Initial sync done: \(status.hasCompletedInitialSync ? "yes" : "no")")
        lines.append("Last sync: \(status.lastReconcile.map(DiagnosticDateFormat.entry.string(from:)) ?? "never")")
        if let error = status.lastError {
            lines.append("Last error: \(LogRedaction.scrubURLs(in: error))")
        }
        return lines
    }

    static func lumeCloudStateLabel(_ state: LumeCloudSyncState) -> String {
        switch state {
        case .notJoined: "not joined"
        case .joined: "joined"
        case .syncing: "syncing"
        case let .uploading(completed, total): "uploading \(completed) of \(total)"
        case .revoked: "device removed"
        case .accountDeleted: "account deleted"
        case .rateLimited: "rate limited"
        case .quotaExceeded: "quota exceeded"
        case .offline: "offline"
        }
    }

    /// Every scalar preference (flags, numbers) plus the player's short string
    /// settings. Scalars can't carry personal data; strings are held to the
    /// `player.` keys, which are engine names and modes.
    static func settingsLines(_ defaults: UserDefaults) -> [String] {
        // Lume's keys are lowercase and dotted ("player.ks.hardwareDecode");
        // the system and SDK domains mixed into `standard` are capitalized.
        let excludedPrefixes = ["com.", "diagnostics.", "debug.logging.enabledSince"]
        var lines: [String] = []
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.count < 80, key.first?.isLowercase == true, key.contains("."),
                  !excludedPrefixes.contains(where: { key.hasPrefix($0) })
            else { continue }
            // Keys carrying an id ("progress.<uuid>") are per-item state, not settings.
            guard key.firstMatch(of: /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}/) == nil else { continue }
            switch value {
            case let number as NSNumber:
                let rendered = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "on" : "off") : number.stringValue
                lines.append("\(key) = \(rendered)")
            case let string as String where key.hasPrefix("player.") && string.count <= 40 && !string.contains("://"):
                lines.append("\(key) = \(string)")
            default:
                continue
            }
        }
        return lines.sorted().prefix(250).map(\.self)
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
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (Simulator)"
        }
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
}

//
//  AppPerformanceMetrics.swift
//  Lume
//
//  The field layer of performance testing: MetricKit.
//
//  Signposts and `LumePerformanceTests` tell us whether a phase regressed on
//  *our* machine. MetricKit tells us what users actually experience — daily
//  aggregates of launch time, hang rate, scroll hitch ratio, memory and disk
//  writes, plus diagnostics for hangs and crashes, all sampled by the OS with no
//  measurement overhead of ours.
//
//  Payloads arrive at most once a day (and on the next launch after one was
//  queued), so this only ever runs cold. Each payload is summarized into the
//  unified log — where the debug log exporter picks it up — and its raw JSON is
//  kept on disk so a support report can carry the full histograms.
//
//  MetricKit is unavailable on tvOS, so the whole subscriber compiles out there.
//

import Foundation
import OSLog

#if canImport(MetricKit) && !os(tvOS)
    import MetricKit

    /// Subscribes to MetricKit for the lifetime of the process.
    final class AppPerformanceMetrics: NSObject, MXMetricManagerSubscriber {
        static let shared = AppPerformanceMetrics()

        /// The most recent payload summary, for the debug screen.
        private(set) var latestSummary: [String] = []

        private var isRegistered = false

        /// Register with MetricKit. Idempotent; call once at launch.
        func start() {
            guard !isRegistered else { return }
            isRegistered = true
            MXMetricManager.shared.add(self)
            Logger.performance.info("MetricKit subscriber registered")
        }

        // MARK: - Metrics

        func didReceive(_ payloads: [MXMetricPayload]) {
            for payload in payloads {
                let lines = Self.summarize(payload)
                latestSummary = lines
                for line in lines {
                    Logger.performance.info("MetricKit \(line, privacy: .public)")
                }
                Self.archive(payload.jsonRepresentation(), kind: "metrics", date: payload.timeStampEnd)
            }
        }

        // MARK: - Diagnostics

        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            for payload in payloads {
                var counts = [
                    ("hang", payload.hangDiagnostics?.count ?? 0),
                    ("crash", payload.crashDiagnostics?.count ?? 0),
                    ("diskWrite", payload.diskWriteExceptionDiagnostics?.count ?? 0)
                ]
                // Launch diagnostics are iOS-family only.
                #if !os(macOS)
                    counts.append(("launch", payload.appLaunchDiagnostics?.count ?? 0))
                #endif
                counts = counts.filter { $0.1 > 0 }
                let description = counts.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
                if !description.isEmpty {
                    Logger.performance.error("MetricKit diagnostics \(description, privacy: .public)")
                }
                for hang in payload.hangDiagnostics ?? [] {
                    let duration = hang.hangDuration.converted(to: .seconds).value
                    Logger.performance.error(
                        "MetricKit hang \(duration, format: .fixed(precision: 2), privacy: .public)s"
                    )
                }
                Self.archive(payload.jsonRepresentation(), kind: "diagnostics", date: payload.timeStampEnd)
            }
        }

        // MARK: - Summarizing

        /// A handful of headline numbers from a daily payload. Deliberately
        /// short: the archived JSON keeps the full detail.
        static func summarize(_ payload: MXMetricPayload) -> [String] {
            var lines: [String] = []

            if let launch = payload.applicationLaunchMetrics {
                if let mean = meanMilliseconds(launch.histogrammedTimeToFirstDraw) {
                    lines.append("timeToFirstDraw≈\(Int(mean))ms")
                }
                if let mean = meanMilliseconds(launch.histogrammedApplicationResumeTime) {
                    lines.append("resumeTime≈\(Int(mean))ms")
                }
            }
            if let responsiveness = payload.applicationResponsivenessMetrics,
               let mean = meanMilliseconds(responsiveness.histogrammedApplicationHangTime)
            {
                lines.append("hangTime≈\(Int(mean))ms")
            }
            if let animation = payload.animationMetrics {
                let ratio = animation.scrollHitchTimeRatio.value
                lines.append("scrollHitchRatio=\(String(format: "%.4f", ratio))")
            }
            if let memory = payload.memoryMetrics {
                let peak = memory.peakMemoryUsage.converted(to: .megabytes).value
                lines.append("peakMemory=\(Int(peak))MB")
            }
            if let disk = payload.diskIOMetrics {
                let written = disk.cumulativeLogicalWrites.converted(to: .megabytes).value
                lines.append("logicalWrites=\(Int(written))MB")
            }
            if let exits = payload.applicationExitMetrics {
                let watchdogs = exits.foregroundExitData.cumulativeAppWatchdogExitCount
                if watchdogs > 0 {
                    lines.append("watchdogExits=\(watchdogs)")
                }
            }
            return lines.isEmpty ? ["payload contained no metrics"] : lines
        }

        /// Bucket-weighted mean of a duration histogram, in milliseconds.
        /// MetricKit reports histograms rather than raw samples, so a mean is the
        /// most we can reconstruct — the archived JSON keeps the buckets.
        private static func meanMilliseconds(_ histogram: MXHistogram<UnitDuration>) -> Double? {
            var totalCount = 0
            var weighted = 0.0
            let enumerator = histogram.bucketEnumerator
            while let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> {
                let start = bucket.bucketStart.converted(to: .milliseconds).value
                let end = bucket.bucketEnd.converted(to: .milliseconds).value
                let midpoint = (start + end) / 2
                weighted += midpoint * Double(bucket.bucketCount)
                totalCount += bucket.bucketCount
            }
            guard totalCount > 0 else { return nil }
            return weighted / Double(totalCount)
        }

        // MARK: - Archiving

        /// Where archived payloads live. Excluded from backup — they are
        /// re-derivable diagnostics, not user data.
        static var archiveDirectory: URL? {
            guard let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first else { return nil }
            return support.appendingPathComponent("Diagnostics", isDirectory: true)
        }

        /// Keeps the newest payloads and prunes the rest, so the directory can't
        /// grow without bound on a long-lived install.
        private static let maxArchivedPayloads = 14

        private static func archive(_ json: Data, kind: String, date: Date) {
            guard let directory = archiveDirectory else { return }
            let manager = FileManager.default
            do {
                if !manager.fileExists(atPath: directory.path) {
                    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                    var resourceValues = URLResourceValues()
                    resourceValues.isExcludedFromBackup = true
                    var mutableDirectory = directory
                    try? mutableDirectory.setResourceValues(resourceValues)
                }
                let name = "\(kind)-\(Int(date.timeIntervalSince1970)).json"
                try json.write(to: directory.appendingPathComponent(name), options: .atomic)
                prune(in: directory)
            } catch {
                let reason = error.localizedDescription
                Logger.performance.error("MetricKit archive failed: \(reason, privacy: .public)")
            }
        }

        private static func prune(in directory: URL) {
            let manager = FileManager.default
            let contents = (try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            guard contents.count > maxArchivedPayloads else { return }
            let sorted = contents.sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast)
            }
            for url in sorted.dropFirst(maxArchivedPayloads) {
                try? manager.removeItem(at: url)
            }
        }
    }
#endif

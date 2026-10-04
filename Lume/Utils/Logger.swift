//
//  Logger.swift
//  Lume
//
//  The app's log categories. Each is a `LumeLogger`, which keeps the familiar
//  `Logger.network.error("… \(value, privacy: .public)")` call shape but tees
//  every message into two sinks:
//
//  1. The OS unified log, for Console.app, Xcode and Instruments.
//  2. `DiagnosticJournal`, an app-owned file the diagnostic report is built
//     from. The unified log alone can't carry a usable report: on device it
//     persists neither `.debug` nor (normally) `.info` entries, renders every
//     default-privacy value as `<private>`, and an in-process `OSLogStore`
//     only sees the current launch — so a sync that failed yesterday, or a
//     crash, left nothing behind to send.
//
//  Privacy in the journal: `.public` and default-privacy values are written
//  through `LogRedaction` (URLs and Basic credentials scrubbed), `.private`
//  values become `<private>`, and `.private(mask: .hash)` a stable short hash
//  so the same value can be correlated across lines without being disclosed.
//  Anything that can carry a username, password or MAC must be `.private`.
//

import Foundation
import OSLog

nonisolated extension Logger {
    static let database = LumeLogger(category: "Database")
    static let network = LumeLogger(category: "Network")
    static let player = LumeLogger(category: "Player")
    static let sync = LumeLogger(category: "CloudSync")
    static let downloads = LumeLogger(category: "Downloads")
    static let indexing = LumeLogger(category: "Indexing")
    static let premium = LumeLogger(category: "Premium")
    static let memory = LumeLogger(category: "Memory")
    static let review = LumeLogger(category: "Review")
    static let storage = LumeLogger(category: "Storage")
    static let metadata = LumeLogger(category: "Metadata")
    static let recording = LumeLogger(category: "Recording")
    /// App lifecycle and user-reported problems — the spine of a report.
    static let app = LumeLogger(category: "App")
    /// Shares its category with `Perf`'s signposts, so one filter shows both the
    /// phase boundaries and the messages explaining them.
    static let performance = LumeLogger(category: "Performance")
}

// MARK: - Levels

nonisolated enum DiagnosticLevel: String, CaseIterable {
    case debug
    case info
    case notice
    case warning
    case error
    case fault

    /// Warnings and worse are what "Recent problems" lists and what forces an
    /// immediate journal flush (the process may be about to die).
    var isProblem: Bool {
        switch self {
        case .warning, .error, .fault: true
        case .debug, .info, .notice: false
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        // `os.Logger.warning` is itself an alias for `.error`.
        case .warning, .error: .error
        case .fault: .fault
        }
    }
}

// MARK: - Logger

nonisolated struct LumeLogger {
    let category: String
    private let osLog: OSLog
    private let osLogger: Logger

    init(category: String) {
        self.category = category
        osLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.bilipp.lume", category: category)
        osLogger = Logger(osLog)
    }

    func debug(_ message: @autoclosure () -> LumeLogMessage) {
        emit(.debug, message)
    }

    func trace(_ message: @autoclosure () -> LumeLogMessage) {
        emit(.debug, message)
    }

    func info(_ message: @autoclosure () -> LumeLogMessage) {
        emit(.info, message)
    }

    func notice(_ message: @autoclosure () -> LumeLogMessage) {
        emit(.notice, message)
    }

    func log(_ message: @autoclosure () -> LumeLogMessage) {
        emit(.notice, message)
    }

    func warning(_ message: @autoclosure () -> LumeLogMessage) {
        emit(.warning, message)
    }

    func error(_ message: @autoclosure () -> LumeLogMessage) {
        emit(.error, message)
    }

    func fault(_ message: @autoclosure () -> LumeLogMessage) {
        emit(.fault, message)
    }

    func critical(_ message: @autoclosure () -> LumeLogMessage) {
        emit(.fault, message)
    }

    private func emit(_ level: DiagnosticLevel, _ message: () -> LumeLogMessage) {
        let journal = DiagnosticJournal.shared
        let wantsJournal = journal.accepts(level)
        #if DEBUG
            let wantsOS = true
        #else
            // Ask the `OSLog`, not the `Logger`: `Logger.isEnabled(type:)`
            // only exists in the OS 26 libswiftos, yet the SDK lets it inherit
            // Logger's OS 14 availability, so it compiles against an 18.0
            // target and binds strongly — every OS 18 launch then dies in dyld
            // ("Symbol missing"), and `#available` can't help. `OSLog`'s is
            // `os_log_type_enabled` from libSystem.
            let wantsOS = osLog.isEnabled(type: level.osLogType)
        #endif
        guard wantsJournal || wantsOS else { return }

        let rendered = message()
        if wantsOS {
            #if DEBUG
                let text = rendered.full
            #else
                let text = rendered.redacted
            #endif
            osLogger.log(level: level.osLogType, "\(text, privacy: .public)")
        }
        if wantsJournal {
            journal.record(level: level, category: category, message: rendered.redacted)
        }
    }
}

// MARK: - Message

/// A log message rendered twice while it's interpolated: `redacted` honours the
/// per-value privacy and is what leaves the device; `full` (DEBUG only) keeps
/// every value for the Xcode console.
nonisolated struct LumeLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
    fileprivate(set) var redacted: String
    #if DEBUG
        fileprivate(set) var full: String
    #endif

    init(stringLiteral value: String) {
        redacted = value
        #if DEBUG
            full = value
        #endif
    }

    init(stringInterpolation: Interpolation) {
        redacted = stringInterpolation.redacted
        #if DEBUG
            full = stringInterpolation.full
        #endif
    }

    struct Interpolation: StringInterpolationProtocol {
        fileprivate var redacted = ""
        #if DEBUG
            fileprivate var full = ""
        #endif

        init(literalCapacity: Int, interpolationCount _: Int) {
            redacted.reserveCapacity(literalCapacity * 2)
        }

        mutating func appendLiteral(_ literal: String) {
            append(literal, publicForm: literal)
        }

        /// Numbers and flags carry no personal data, so the default is public —
        /// the same default `os_log` applies.
        mutating func appendInterpolation(_ value: some BinaryInteger, privacy: LumeLogPrivacy = .public) {
            appendValue(String(value), privacy: privacy)
        }

        mutating func appendInterpolation(_ value: Bool, privacy: LumeLogPrivacy = .public) {
            appendValue(String(value), privacy: privacy)
        }

        mutating func appendInterpolation(
            _ value: some BinaryFloatingPoint,
            format: LumeLogFloatFormat = .automatic,
            privacy: LumeLogPrivacy = .public
        ) {
            appendValue(format.render(Double(value)), privacy: privacy)
        }

        /// Errors render as a credential-free chain (type, domain/code,
        /// underlying errors) — see `LogRedaction.describe(_:)`.
        mutating func appendInterpolation(_ error: some Error, privacy: LumeLogPrivacy = .public) {
            appendValue(LogRedaction.describe(error), privacy: privacy)
        }

        mutating func appendInterpolation(_ error: (any Error)?, privacy: LumeLogPrivacy = .public) {
            appendValue(error.map(LogRedaction.describe) ?? "nil", privacy: privacy)
        }

        mutating func appendInterpolation(_ value: some Any, privacy: LumeLogPrivacy = .public) {
            appendValue(String(describing: value), privacy: privacy)
        }

        private mutating func appendValue(_ value: String, privacy: LumeLogPrivacy) {
            let publicForm: String = switch privacy.kind {
            case .public: LogRedaction.scrubURLs(in: value)
            case .private: "<private>"
            case .hash: "<hash:\(LogRedaction.stableHash(value))>"
            }
            append(value, publicForm: publicForm)
        }

        private mutating func append(_ value: String, publicForm: String) {
            redacted += publicForm
            #if DEBUG
                full += value
            #endif
        }
    }
}

// MARK: - Privacy / format

/// Mirrors the subset of `OSLogPrivacy` the app uses, so call sites read the
/// same as plain `os.Logger` ones.
nonisolated struct LumeLogPrivacy {
    enum Kind { case `public`, `private`, hash }

    nonisolated enum Mask { case hash }

    let kind: Kind

    static let `public` = LumeLogPrivacy(kind: .public)
    static let `private` = LumeLogPrivacy(kind: .private)

    static func `private`(mask: Mask) -> LumeLogPrivacy {
        switch mask {
        case .hash: LumeLogPrivacy(kind: .hash)
        }
    }
}

nonisolated struct LumeLogFloatFormat {
    private let precision: Int?

    static let automatic = LumeLogFloatFormat(precision: nil)

    static func fixed(precision: Int) -> LumeLogFloatFormat {
        LumeLogFloatFormat(precision: precision)
    }

    func render(_ value: Double) -> String {
        guard let precision else { return String(value) }
        return String(format: "%.\(precision)f", value)
    }
}

//
//  CloudSyncErrorDescription.swift
//  Lume
//
//  Renders a CloudKit sync error twice: once for `Logger.sync` (domain, code,
//  CKError case name, and the whole `NSUnderlyingErrorKey` chain) and once for
//  the iCloud row in settings (a human sentence naming the cause).
//
//  `localizedDescription` alone is not enough for either. For
//  `CKError.partialFailure` it reads "The operation couldn't be completed.
//  (CKErrorDomain error 2.)", which makes a per-record rejection, a quota
//  problem, and a zone-level failure indistinguishable after the fact — that
//  ambiguity is what sent #155 chasing a CloudKit schema that turned out to be
//  in sync.
//
//  Everything here is bound for `privacy: .public` log interpolation and lands
//  verbatim in user-exported diagnostics, so messages pass through
//  `LogRedaction` and `userInfo` is never rendered: CloudKit conflict errors
//  carry whole `CKRecord`s, and a synced playlist record holds the server URL
//  and account credentials.
//

import CloudKit
import Foundation

nonisolated enum CloudSyncErrorDescription {
    /// The first `CKError` reachable from `error` through the underlying-error
    /// chain. The error on an `NSPersistentCloudKitContainer` event is usually
    /// the `CKError` itself, but it also arrives wrapped in a Cocoa error —
    /// sometimes more than one level deep, which a single `userInfo` lookup
    /// misses.
    static func ckError(in error: Error) -> CKError? {
        for link in chain(from: error) {
            if let ckError = link as? CKError {
                return ckError
            }
        }
        return nil
    }

    /// Diagnostic rendering for the log: every link of the underlying-error
    /// chain as `domain code (ckCase): message`, newest first.
    static func logDetail(for error: Error) -> String {
        chain(from: error).map(detail(for:)).joined(separator: " ← ")
    }

    /// The cause as shown in the iCloud settings row. Known `CKError` codes get
    /// a human sentence; anything else keeps the system wording but gains the
    /// `CKError` case name, so even an unmapped failure is identifiable from a
    /// screenshot instead of reading as a bare number.
    static func message(for error: Error) -> String {
        guard let ckError = ckError(in: error) else { return error.localizedDescription }
        if let mapped = mapped(ckError.code) {
            return mapped
        }
        return "\(ckError.localizedDescription) (\(codeName(ckError.code)))"
    }

    // MARK: - Chain

    /// Bounded so a self-referential `NSUnderlyingErrorKey` can't spin.
    private static let maxChainDepth = 4

    private static func chain(from error: Error) -> [Error] {
        var links: [Error] = []
        var current: Error? = error
        while let link = current, links.count < maxChainDepth {
            links.append(link)
            current = (link as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        return links
    }

    private static func detail(for error: Error) -> String {
        let nsError = error as NSError
        var detail = "\(nsError.domain) \(nsError.code)"
        if let ckError = error as? CKError {
            detail += " (\(codeName(ckError.code)))"
            if ckError.code == .partialFailure, ckError.partialErrorsByItemID?.isEmpty ?? true {
                // The emptiness *is* the diagnostic. A rejected record always
                // populates the dictionary, so an empty one rules out the
                // record types and points at the account, zone, or quota (#155).
                detail += " [no per-record errors]"
            }
        }
        return "\(detail): \(LogRedaction.scrubURLs(in: nsError.localizedDescription))"
    }

    private static func codeName(_ code: CKError.Code) -> String {
        codeNames[code.rawValue] ?? "CKErrorCode \(code.rawValue)"
    }

    /// `CKError.Code` is an imported `NS_ENUM`, so `String(describing:)` renders
    /// `CKErrorCode(rawValue: 25)` — the bare number this type exists to
    /// translate. Keyed by `rawValue` rather than by the code so the table stays
    /// a plain `Sendable` literal.
    private static let codeNames: [Int: String] = [
        1: "internalError",
        2: "partialFailure",
        3: "networkUnavailable",
        4: "networkFailure",
        5: "badContainer",
        6: "serviceUnavailable",
        7: "requestRateLimited",
        8: "missingEntitlement",
        9: "notAuthenticated",
        10: "permissionFailure",
        11: "unknownItem",
        12: "invalidArguments",
        14: "serverRecordChanged",
        15: "serverRejectedRequest",
        16: "assetFileNotFound",
        17: "assetFileModified",
        18: "incompatibleVersion",
        19: "constraintViolation",
        20: "operationCancelled",
        21: "changeTokenExpired",
        22: "batchRequestFailed",
        23: "zoneBusy",
        24: "badDatabase",
        25: "quotaExceeded",
        26: "zoneNotFound",
        27: "limitExceeded",
        28: "userDeletedZone",
        29: "tooManyParticipants",
        30: "alreadyShared",
        31: "referenceViolation",
        32: "managedAccountRestricted",
        33: "participantMayNeedVerification",
        34: "serverResponseLost",
        35: "assetNotAvailable",
        36: "accountTemporarilyUnavailable"
    ]

    // MARK: - User-facing mapping

    private static func mapped(_ code: CKError.Code) -> String? {
        switch code {
        case .quotaExceeded:
            String(localized: "Your iCloud storage is full. Free up space or upgrade your plan to resume syncing.")
        case .networkUnavailable, .networkFailure:
            String(localized: "No connection to iCloud. Sync resumes when you’re back online.")
        case .notAuthenticated:
            String(localized: "Sign in to iCloud to resume syncing.")
        case .accountTemporarilyUnavailable:
            String(localized: "Your iCloud account is temporarily unavailable. Sync resumes automatically.")
        case .managedAccountRestricted, .permissionFailure:
            String(localized: "This iCloud account isn’t permitted to sync.")
        case .zoneBusy, .requestRateLimited, .serviceUnavailable:
            String(localized: "iCloud is busy. Sync will retry automatically.")
        case .serverRecordChanged:
            String(localized: "The same item changed on another device. Sync merges it on the next pass.")
        case .partialFailure:
            String(localized: "iCloud rejected some changes. Export a diagnostic report for details.")
        default:
            nil
        }
    }
}

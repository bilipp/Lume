//
//  LumeCloudErrorDescription.swift
//  Lume
//
//  Renders a Lume Cloud error twice: once for `Logger.sync` (the case name,
//  HTTP status and server error code) and once for the Sync settings row (a
//  localized sentence). `LumeCloudError.errorDescription` is English-only and
//  quotes the server's free-text message, so neither rendering uses it.
//
//  The log detail lands verbatim in user-exported diagnostics. It never carries
//  the server's message, a URL, an account or device id, a key, a pairing code
//  or a payload — only values the error type itself enumerates.
//

import Foundation
import LumeCloudKit

nonisolated enum LumeCloudErrorDescription {
    /// The cause as shown in the Sync settings row.
    static func message(for error: any Error) -> String {
        if let accountError = error as? LumeCloudAccountError {
            return message(for: accountError)
        }
        if let switchError = error as? SyncBackendSwitchError {
            switch switchError {
            case .notJoined: return message(for: LumeCloudAccountError.notJoined)
            case .unavailable: return message(for: LumeCloudAccountError.unavailable)
            }
        }
        guard let cloudError = error as? LumeCloudError else {
            return LogRedaction.scrubURLs(in: error.localizedDescription)
        }
        return message(for: cloudError)
    }

    /// The cause after a one-off user action (create, delete, rename), where
    /// "sync will retry automatically" would promise a retry nobody runs.
    static func actionMessage(for error: any Error) -> String {
        switch error as? LumeCloudError {
        case .transport, .server:
            String(localized: "Lume Cloud can’t be reached right now. Try again in a moment.")
        case .rateLimited:
            String(localized: "Lume Cloud is busy. Try again in a moment.")
        default:
            message(for: error)
        }
    }

    /// Diagnostic rendering for the log, e.g. `server(status: 503, code: unavailable)`.
    static func logDetail(for error: any Error) -> String {
        guard let cloudError = error as? LumeCloudError else {
            return LogRedaction.describe(error)
        }
        return logDetail(for: cloudError)
    }

    static func message(for error: LumeCloudError) -> String { // swiftlint:disable:this cyclomatic_complexity
        switch error {
        case .badRequest:
            String(localized: "Lume Cloud rejected a request. Export a diagnostic report for details.")
        case .badAuth:
            String(localized: "Lume Cloud didn’t accept this device’s sign-in.")
        case .deviceRevoked:
            String(localized: "This device was removed from Lume Cloud. Your data stays on this device.")
        case .signupClosed:
            String(localized: "This Lume Cloud server isn’t accepting new accounts.")
        case .accountDeleted:
            String(localized: "Your Lume Cloud account was deleted. Your data stays on this device.")
        case .notFound:
            String(localized: "The pairing code is wrong or has expired.")
        case .accountExists:
            String(localized: "This account already exists. Join with a code or your recovery key instead.")
        case .pairingAlreadySealed:
            String(localized: "Another device already answered this pairing code.")
        case .resyncRequired:
            String(localized: "Lume Cloud is syncing everything again. This happens automatically.")
        case .recordTooLarge:
            String(localized: "An item is too large for Lume Cloud and stays on this device.")
        case .rateLimited:
            String(localized: "Lume Cloud is busy. Sync will retry automatically.")
        case .quotaExceeded:
            String(localized: "Lume Cloud storage is full. New changes stay on this device.")
        case .server:
            String(localized: "Lume Cloud ran into a problem. Sync will retry automatically.")
        case .transport:
            String(localized: "Lume Cloud can’t be reached. Sync resumes automatically.")
        case .decoding:
            String(localized: "Lume Cloud sent a response this version of Lume can’t read. Update Lume to resume syncing.")
        case .missingCredentials:
            String(localized: "Lume Cloud isn’t set up on this device.")
        }
    }

    static func message(for error: LumeCloudAccountError) -> String { // swiftlint:disable:this cyclomatic_complexity
        switch error {
        case .unavailable:
            String(localized: "Lume Cloud isn’t available right now.")
        case .notJoined:
            String(localized: "Turn on Lume Cloud on this device first.")
        case .alreadyJoined:
            String(localized: "This device already syncs with Lume Cloud.")
        case .keychainUnavailable:
            String(localized: "Lume couldn’t save the Lume Cloud key on this device. Unlock the device and try again.")
        case .invalidPairingCode:
            String(localized: "Enter the 6-digit code shown on the new device.")
        case .pairingExpired:
            String(localized: "The pairing code is wrong or has expired.")
        case .pairingFailed:
            String(localized: "Pairing didn’t finish. Start again on the new device.")
        case .serverMismatch:
            String(localized: "That device uses a different Lume Cloud server.")
        case .cannotRevokeCurrentDevice:
            String(localized: "To remove this device, leave Lume Cloud instead.")
        case .invalidRecoveryKey:
            String(localized: "That isn’t a recovery key.")
        case .recoveryKeyTypo:
            String(localized: "The recovery key has a typo. Check it and try again.")
        case .wrongRecoveryKey:
            String(localized: "This recovery key doesn’t belong to a Lume Cloud account.")
        }
    }

    static func logDetail(for error: LumeCloudError) -> String {
        switch error {
        case let .rateLimited(retryAfter):
            retryAfter.map { "rateLimited(retryAfter: \(Int($0.rounded(.up)))s)" } ?? "rateLimited"
        case let .server(status, code):
            "server(status: \(status), code: \(code.map(errorCode) ?? "none"))"
        case let .transport(urlError):
            "transport(NSURLErrorDomain \(urlError.code.rawValue))"
        case let .decoding(path):
            "decoding(\(LogRedaction.scrubURLs(in: path)))"
        default:
            // The case name alone: `badRequest`'s server message is free text.
            Mirror(reflecting: error).children.first?.label ?? String(describing: error)
        }
    }

    /// Server error codes are snake_case identifiers; anything else is reduced
    /// to its allowed characters so a misbehaving proxy can't inject prose.
    private static func errorCode(_ code: String) -> String {
        String(code.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.prefix(40))
    }
}

nonisolated extension LumeCloudError: DiagnosticErrorDescribing {
    var logDescription: String {
        LumeCloudErrorDescription.logDetail(for: self)
    }
}

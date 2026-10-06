//
//  RecordingActionError.swift
//  Lume
//
//  Why a Record / Schedule / Stop / Delete / Play action on the recording
//  server didn't go through — the app-side gates first, then whatever the
//  server said, wrapped as `RecordingServerError`.
//

import Foundation

nonisolated enum RecordingActionError: LocalizedError, Equatable {
    /// Lume Pro is required for every recording-server action.
    case premiumRequired
    case notPaired
    /// This playlist kind can't hand a recording server a standalone stream URL.
    case unsupportedSource
    /// This playlist kind's stream URLs expire, so it can only record now.
    case scheduleUnsupported
    /// No programme is on air; the caller asks for a fallback duration.
    case durationRequired
    /// The programme has already started or ended, so there is nothing to schedule.
    case programmeNotUpcoming
    /// The channel has no playable URL, or the portal didn't issue one.
    case streamUnavailable
    case server(RecordingServerError)

    var errorDescription: String? {
        switch self {
        case .premiumRequired:
            String(localized: "Recording requires Lume Pro.")
        case .notPaired:
            String(localized: "Pair a recording server in Settings to record live TV.")
        case .unsupportedSource:
            String(localized: "Channels from this playlist can't be recorded.")
        case .scheduleUnsupported:
            String(localized: "Channels from this playlist can only be recorded while they're on air.")
        case .durationRequired:
            String(localized: "Choose how long to record.")
        case .programmeNotUpcoming:
            String(localized: "This programme has already started.")
        case .streamUnavailable:
            String(localized: "Lume couldn't get a stream address for this channel.")
        case let .server(error):
            error.errorDescription
        }
    }

    /// Safe for `privacy: .public`: case names only, never a URL or token.
    var logDescription: String {
        switch self {
        case .premiumRequired: "premium required"
        case .notPaired: "no paired server"
        case .unsupportedSource: "unsupported source type"
        case .scheduleUnsupported: "source type can't schedule"
        case .durationRequired: "no programme on air, duration required"
        case .programmeNotUpcoming: "programme not upcoming"
        case .streamUnavailable: "no stream URL"
        case let .server(error): error.logDescription
        }
    }
}

nonisolated extension RecordingActionError: DiagnosticErrorDescribing {}

//
//  SyncError.swift
//  Lume
//
//  Split out of ContentSyncManager.swift, which sits at SwiftLint's 600-line
//  file cap.
//

import Foundation

enum SyncError: LocalizedError {
    case syncInProgress
    case playlistNotFound
    case invalidCredentials
    case networkError(Error)
    case databaseError(Error)
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .syncInProgress:
            "A sync is already in progress for this playlist"
        case .playlistNotFound:
            "The playlist could not be found"
        case .invalidCredentials:
            "Invalid username or password"
        case let .networkError(error):
            "Network error: \(error.localizedDescription)"
        case let .databaseError(error):
            "Database error: \(error.localizedDescription)"
        case .notImplemented:
            "This playlist type cannot be synced by this version of Lume"
        }
    }
}

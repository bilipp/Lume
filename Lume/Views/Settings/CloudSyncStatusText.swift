//
//  CloudSyncStatusText.swift
//  Lume
//
//  `CloudSyncStatusText`: the sync status wording shared by Settings ▸ Sync
//  on every platform (`SyncSettingsView` on iOS / macOS / visionOS,
//  `TVSyncSettingsPane` on tvOS).
//

import LumeCloudKit
import SwiftUI

// MARK: - Shared status text

/// Maps the observable status into localized, human strings — kept in one place
/// so both platforms read identically.
enum CloudSyncStatusText {
    static func accountDescription(_ account: CloudAccountStatus) -> LocalizedStringKey {
        switch account {
        case .unknown: "Checking…"
        case .available: "On"
        case .noAccount: "No iCloud Account"
        case .restricted: "Restricted"
        case .temporarilyUnavailable: "Temporarily Unavailable"
        case .couldNotDetermine: "Unavailable"
        }
    }

    /// The secondary, explanatory line under the account row.
    static func detail(for status: CloudSyncStatus) -> Text {
        switch status.backend {
        case .icloud: iCloudDetail(for: status)
        case .lumecloud: lumeCloudDetail(for: status)
        case .off: Text("Sync is off. Changes stay on this device.")
        }
    }

    /// One word for the root Settings row: "Synced", or what's in the way.
    static func summary(_ status: CloudSyncStatus) -> LocalizedStringKey {
        switch status.backend {
        case .icloud: iCloudSummary(status)
        case .lumecloud: lumeCloudSummary(status)
        case .off: "Off"
        }
    }

    private static func iCloudDetail(for status: CloudSyncStatus) -> Text {
        if status.isSyncing {
            return Text("Syncing…")
        }
        if let error = status.lastError, status.account.canSync {
            return Text("Sync error: \(error)")
        }
        switch status.account {
        case .available:
            return lastSyncedText(status)
        case .noAccount:
            return Text("Sign in to iCloud in Settings to sync your playlists and viewing across devices.")
        case .restricted:
            return Text("iCloud is restricted on this device (e.g. by Screen Time or a profile).")
        case .temporarilyUnavailable:
            return Text("iCloud is temporarily unavailable. Sync resumes automatically.")
        case .couldNotDetermine, .unknown:
            return Text("iCloud status couldn’t be determined.")
        }
    }

    private static func iCloudSummary(_ status: CloudSyncStatus) -> LocalizedStringKey {
        if status.isSyncing {
            return "Syncing…"
        }
        if status.lastError != nil, status.account.canSync {
            return "Error"
        }
        if status.account == .available, status.lastReconcile != nil {
            return "Synced"
        }
        return accountDescription(status.account)
    }

    private static func lumeCloudDetail(for status: CloudSyncStatus) -> Text {
        switch status.lumeCloud {
        case .notJoined:
            Text(verbatim: LumeCloudErrorDescription.message(for: LumeCloudError.missingCredentials))
        case .joined:
            lumeCloudJoinedDetail(for: status)
        case .syncing:
            Text("Syncing…")
        case let .uploading(completed, total):
            Text("Uploading \(completed) of \(total)")
        case .revoked:
            Text(verbatim: LumeCloudErrorDescription.message(for: LumeCloudError.deviceRevoked))
        case .accountDeleted:
            Text(verbatim: LumeCloudErrorDescription.message(for: LumeCloudError.accountDeleted))
        case .rateLimited:
            Text(verbatim: LumeCloudErrorDescription.message(for: LumeCloudError.rateLimited(retryAfter: nil)))
        case .quotaExceeded:
            Text(verbatim: LumeCloudErrorDescription.message(for: LumeCloudError.quotaExceeded))
        case .offline:
            Text(verbatim: LumeCloudErrorDescription.message(for: LumeCloudError.transport(URLError(.notConnectedToInternet))))
        }
    }

    private static func lumeCloudJoinedDetail(for status: CloudSyncStatus) -> Text {
        if let error = status.lastError {
            return Text("Sync error: \(error)")
        }
        return lastSyncedText(status)
    }

    private static func lastSyncedText(_ status: CloudSyncStatus) -> Text {
        if let date = status.lastReconcile {
            return Text("Last synced \(Text(date, format: .relative(presentation: .named)))")
        }
        return Text("Waiting for first sync…")
    }

    private static func lumeCloudSummary(_ status: CloudSyncStatus) -> LocalizedStringKey {
        switch status.lumeCloud {
        case .notJoined: "Not Set Up"
        case .joined where status.lastError != nil: "Error"
        case .joined where status.lastReconcile != nil: "Synced"
        case .joined: "On"
        case .syncing, .uploading: "Syncing…"
        case .revoked: "Removed"
        case .accountDeleted: "Account Deleted"
        case .rateLimited: "Busy"
        case .quotaExceeded: "Storage Full"
        case .offline: "Offline"
        }
    }

    static var footer: LocalizedStringKey {
        "Your playlists, watch progress, favorites and watchlist sync across your devices through your private iCloud account. The video catalog itself is fetched on each device and isn’t uploaded."
    }
}

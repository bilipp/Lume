//
//  CloudSyncSettingsView.swift
//  Lume
//
//  Settings UI for iCloud sync status. Two presentations share one source of
//  truth (`CloudSyncCoordinator` in the environment): a grouped-list `Section`
//  on iOS / macOS and a tvOS detail block matching the Apple TV Settings style.
//
//  The coordinator is looked up optionally so SwiftUI previews (which don't
//  inject it) render without crashing.
//

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
        if status.isSyncing {
            return Text("Syncing…")
        }
        if let error = status.lastError, status.account.canSync {
            return Text("Sync error: \(error)")
        }
        switch status.account {
        case .available:
            if let date = status.lastReconcile {
                return Text("Last synced \(Text(date, format: .relative(presentation: .named)))")
            }
            return Text("Waiting for first sync…")
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

    static var footer: LocalizedStringKey {
        "Your playlists, watch progress, favorites and watchlist sync across your devices through your private iCloud account. The video catalog itself is fetched on each device and isn’t uploaded."
    }
}

// MARK: - iOS / macOS

#if !os(tvOS)
    struct CloudSyncSection: View {
        @Environment(CloudSyncCoordinator.self) private var coordinator: CloudSyncCoordinator?

        var body: some View {
            if let coordinator {
                let status = coordinator.status
                Section {
                    HStack {
                        Label("iCloud Sync", systemImage: iconName(for: status))
                        Spacer()
                        Text(CloudSyncStatusText.accountDescription(status.account))
                            .foregroundStyle(.secondary)
                    }
                    CloudSyncStatusText.detail(for: status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("iCloud")
                } footer: {
                    Text(CloudSyncStatusText.footer)
                }
            }
        }

        private func iconName(for status: CloudSyncStatus) -> String {
            if status.isSyncing { return "arrow.triangle.2.circlepath.icloud" }
            switch status.account {
            case .available: return "checkmark.icloud"
            case .noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable: return "xmark.icloud"
            case .unknown: return "icloud"
            }
        }
    }
#endif

// MARK: - tvOS

#if os(tvOS)
    struct TVCloudSyncSection: View {
        @Environment(CloudSyncCoordinator.self) private var coordinator: CloudSyncCoordinator?

        var body: some View {
            if let coordinator {
                let status = coordinator.status
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("iCloud")

                    HStack(spacing: 16) {
                        Text("iCloud Sync")
                        Spacer(minLength: 0)
                        if status.isSyncing {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Text(CloudSyncStatusText.accountDescription(status.account))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.vertical, 8)

                    CloudSyncStatusText.detail(for: status)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                    Text(CloudSyncStatusText.footer)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }
            }
        }
    }
#endif

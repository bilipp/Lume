//
//  SettingsView+AutoSync.swift
//  Lume
//
//  The global "Automatic Sync" frequency control in the tvOS Playlists pane,
//  split out of SettingsView to keep that type's body small. The frequency is
//  one shared setting for every playlist (see SyncFrequency); whether a given
//  playlist participates is still gated by its own `syncEnabled` flag, edited in
//  PlaylistDetailView. iOS / macOS show it in `PlaylistsSettingsView`.
//

import SwiftUI

#if os(tvOS)

    extension SettingsView {
        /// Two-way binding over the raw `@AppStorage` string so pickers can work in
        /// terms of `SyncFrequency` directly.
        var syncFrequency: Binding<SyncFrequency> {
            Binding(
                get: { SyncFrequency.resolve(syncFrequencyRaw) },
                set: { syncFrequencyRaw = $0.rawValue }
            )
        }

        /// tvOS detail-pane section, using the same checkmark-row style as the
        /// player engine picker.
        var tvAutoSyncSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Automatic Sync")

                VStack(spacing: 2) {
                    ForEach(SyncFrequency.allCases) { frequency in
                        Button {
                            syncFrequency.wrappedValue = frequency
                        } label: {
                            HStack(spacing: 16) {
                                Text(frequency.label)
                                Spacer(minLength: 0)
                                if syncFrequency.wrappedValue == frequency {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 24, weight: .semibold))
                                }
                            }
                        }
                        .buttonStyle(TVSettingsRowButtonStyle())
                    }
                }

                Text("Playlists refresh automatically in the background at this interval. Disable a specific playlist's sync in its details. The TV guide refreshes on its own schedule.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 6)
            }
        }
    }

#endif

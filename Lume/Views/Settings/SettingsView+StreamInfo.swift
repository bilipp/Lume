//
//  SettingsView+StreamInfo.swift
//  Lume
//
//  The "Stream Information" preferences: whether the in-player caption is shown
//  and how much it spells out. Split out of SettingsView to keep that file
//  within the project's line-count cap.
//
//  Free for everyone — deliberately not premium-gated like the neighbouring
//  Playback toggles.
//

import SwiftUI

extension SettingsView {
    /// The stored detail level, resolved through the same fallback the player
    /// uses so a stale or unknown raw value reads as the platform default.
    var streamInfoDetailLevel: StreamInfoDetailLevel {
        StreamInfoDetailLevel(rawValue: streamInfoDetailLevelRaw) ?? PlayerSettings.StreamInfo.detailLevelDefault
    }

    #if !os(tvOS)
        /// iOS / macOS grouped-list section.
        var streamInfoSection: some View {
            Section {
                Toggle("Show Stream Information", isOn: $streamInfoEnabled)

                if streamInfoEnabled {
                    Picker("Detail Level", selection: $streamInfoDetailLevelRaw) {
                        ForEach(StreamInfoDetailLevel.allCases) { level in
                            Text(level.title).tag(level.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("Stream Information")
            } footer: {
                Text(streamInfoDetailLevel.footer)
            }
        }
    #else
        /// tvOS detail-pane section, using the same checkmark-row style as the
        /// automatic-sync picker. There is no enable toggle here: the caption is
        /// part of the always-on player chrome on tvOS, so only how much it
        /// spells out is a choice.
        var tvStreamInfoSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Stream Information")

                VStack(spacing: 2) {
                    ForEach(StreamInfoDetailLevel.allCases) { level in
                        Button {
                            streamInfoDetailLevelRaw = level.rawValue
                        } label: {
                            HStack(spacing: 16) {
                                Text(level.title)
                                Spacer(minLength: 0)
                                if streamInfoDetailLevel == level {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 24, weight: .semibold))
                                }
                            }
                        }
                        .buttonStyle(TVSettingsRowButtonStyle())
                    }
                }

                Text(streamInfoDetailLevel.footer)
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 6)
            }
        }
    #endif
}

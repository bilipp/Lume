//
//  SettingsView+Indexing.swift
//  Lume
//
//  The content-indexing status section of SettingsView, for both the grouped
//  list (iOS/macOS) and the Apple TV two-pane layout.
//

import SwiftUI

extension SettingsView {
    #if !os(tvOS)
        var indexingSection: some View {
            Section {
                HStack {
                    Label("Content Indexing", systemImage: "sparkles")
                    Spacer()
                    if indexing.state == .indexing || indexing.state == .preparing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 2)
                    }
                    Text(indexing.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Indexing")
            } footer: {
                Text("Matches your library against TMDB and builds an on-device index for smarter search. Runs slowly in the background.")
            }
        }
    #endif

    #if os(tvOS)
        var tvIndexingSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Content Indexing")

                HStack(spacing: 12) {
                    if indexing.state == .indexing || indexing.state == .preparing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(indexing.statusText)
                        .font(.system(size: 24))
                }
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.vertical, 4)

                Text("Matches your library against TMDB and builds an on-device index for smarter search. Runs slowly in the background.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 6)
            }
        }
    #endif
}

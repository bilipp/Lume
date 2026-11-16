//
//  WhatsNewHistoryView.swift
//  Lume
//
//  Every release's changes on this platform, newest first. Reached from
//  Settings › About and from the What's New sheet.
//

import SwiftUI

struct WhatsNewHistoryView: View {
    private let releases = WhatsNewCatalog.history(for: AppVersion(SupportInfo.appVersion), on: .current)

    var body: some View {
        #if os(tvOS)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("What’s New", tableName: "WhatsNew")
                        .font(.title2.bold())
                        .padding(.horizontal, 40)
                    ForEach(releases) { TVWhatsNewReleaseCard(release: $0) }
                }
                .frame(maxWidth: 1200)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
            .background(.regularMaterial)
        #else
            List(releases) { release in
                Section {
                    ForEach(release.highlights(on: .current)) { item in
                        WhatsNewItemRow(item: item)
                            .padding(.vertical, 4)
                    }
                    ForEach(Array(release.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Version \(release.version.displayString)")
                }
            }
            .navigationTitle(Text("What’s New", tableName: "WhatsNew"))
            #if os(iOS) || os(visionOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        #endif
    }
}

#if os(tvOS)
    /// One release as a focus stop, so the remote scrolls the history release
    /// by release.
    private struct TVWhatsNewReleaseCard: View {
        let release: WhatsNewRelease

        @FocusState private var isFocused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 28) {
                Text("Version \(release.version.displayString)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ForEach(release.highlights(on: .current)) { WhatsNewItemRow(item: $0) }
                ForEach(Array(release.notes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.white.opacity(isFocused ? 0.14 : 0.05),
                in: .rect(cornerRadius: 28, style: .continuous)
            )
            .focusable()
            .focused($isFocused)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .accessibilityElement(children: .combine)
        }
    }
#endif

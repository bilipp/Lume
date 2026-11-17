//
//  WhatsNewHistoryView.swift
//  Lume
//
//  Every release this build contains, newest first. Each opens its What's New
//  page again. Reached from Settings › About and from the What's New sheet.
//

import SwiftUI

struct WhatsNewHistoryView: View {
    private let releases = WhatsNewCatalog.history(for: AppVersion(SupportInfo.appVersion), on: .current)

    @State private var selected: WhatsNewRelease?

    var body: some View {
        list
        #if os(tvOS)
        .fullScreenCover(item: $selected) { WhatsNewSheet(release: $0, isReplay: true) }
        #else
        .sheet(item: $selected) { WhatsNewSheet(release: $0, isReplay: true) }
        #endif
    }

    #if os(tvOS)
        private var list: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What’s New", tableName: "WhatsNew")
                        .font(.title2.bold())
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.bottom, 12)
                    ForEach(releases) { release in
                        Button {
                            selected = release
                        } label: {
                            WhatsNewReleaseLabel(release: release)
                        }
                        .buttonStyle(TVSettingsRowButtonStyle())
                    }
                }
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
            .background(.regularMaterial)
        }
    #else
        private var list: some View {
            List(releases) { release in
                Button {
                    selected = release
                } label: {
                    HStack {
                        WhatsNewReleaseLabel(release: release)
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("whatsNew.release.\(release.version.displayString)")
            }
            .navigationTitle(Text("What’s New", tableName: "WhatsNew"))
            #if os(iOS) || os(visionOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    #endif
}

/// A release in the history: its version over the titles of what it brought,
/// or its first note when it had no highlight on this platform.
private struct WhatsNewReleaseLabel: View {
    let release: WhatsNewRelease

    private var highlights: [WhatsNewItem] {
        release.highlights(on: .current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Version \(release.version.displayString)")
                .font(.headline)
            Group {
                if highlights.isEmpty, let note = release.notes.first {
                    Text(note)
                } else {
                    ForEach(highlights) { Text($0.title) }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

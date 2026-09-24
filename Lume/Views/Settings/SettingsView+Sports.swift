//
//  SettingsView+Sports.swift
//  Lume
//
//  The Sports settings entry in the main list and its dedicated pane. Follows the
//  same shape as the TV Guide / Auto-Sync sections: a NavigationLink from the
//  grouped list into `SportsSettingsView`, which manages followed teams, the tab
//  toggle, the refresh schedule and a manual refresh. tvOS reaches the equivalent
//  controls through `TVSportsSettingsPane` (SettingsView+TVComponents), so both
//  the section and the pane below are iOS / macOS / visionOS only.
//

import SwiftUI

#if !os(tvOS)

    extension SettingsView {
        /// iOS / macOS grouped-list section linking to the dedicated Sports pane.
        var sportsSection: some View {
            Section {
                NavigationLink {
                    SportsSettingsView()
                } label: {
                    Label("Sports", systemImage: "sportscourt")
                }
            } header: {
                Text("Sports")
            } footer: {
                Text("Follow leagues and teams to build your Sports Hub.")
            }
        }
    }

    struct SportsSettingsView: View {
        @AppStorage(SportsSyncService.tabEnabledKey) private var tabEnabled = SportsSyncService.tabEnabledDefault
        @AppStorage(SportsSyncService.syncFrequencyKey)
        private var freqRaw = SportsSyncService.defaultFrequency.rawValue
        @State private var sync = SportsSyncService.shared
        @State private var showingManageTeams = false

        private var frequency: Binding<SyncFrequency> {
            Binding(
                get: { SyncFrequency(rawValue: freqRaw) ?? SportsSyncService.defaultFrequency },
                set: { freqRaw = $0.rawValue }
            )
        }

        var body: some View {
            Form {
                teamsSection
                tabSection
                refreshSection
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Sports")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .sheet(isPresented: $showingManageTeams) {
                    ManageTeamsSheet()
                }
        }

        private var teamsSection: some View {
            Section {
                Button {
                    showingManageTeams = true
                } label: {
                    Label("Manage Teams", systemImage: "person.2.badge.plus")
                }
            } header: {
                Text("Following")
            }
        }

        private var tabSection: some View {
            Section {
                Toggle("Show Sports Tab", isOn: $tabEnabled)
            } footer: {
                Text("Show the Sports tab. The fixtures rail on Home follows your Home layout settings.")
            }
        }

        private var refreshSection: some View {
            Section {
                Picker("Refresh", selection: frequency) {
                    ForEach(SyncFrequency.allCases) { frequency in
                        Text(frequency.label).tag(frequency)
                    }
                }
                .pickerStyle(.menu)

                Button {
                    sync.syncNow()
                } label: {
                    HStack {
                        Label("Refresh Now", systemImage: "arrow.triangle.2.circlepath")
                        if sync.isSyncing {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(sync.isSyncing)
            } header: {
                Text("Automatic Refresh")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fixtures, live scores and standings refresh automatically in the background at this interval.")
                    Text(lastRefreshText)
                    Text("Scores and schedules provided by ESPN")
                }
            }
        }

        private var lastRefreshText: String {
            guard let last = sync.lastRefresh else {
                return String(localized: "Sports haven't refreshed yet.")
            }
            let relative = last.formatted(.relative(presentation: .named))
            return String(localized: "Last refreshed \(relative)")
        }
    }

#endif

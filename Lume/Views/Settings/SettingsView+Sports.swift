//
//  SettingsView+Sports.swift
//  Lume
//
//  The Sports settings page behind the root Sports row: followed teams, Hide
//  Scores and a manual refresh. The tab switch lives in Library › Tabs. tvOS
//  reaches the equivalent controls through `TVSportsSettingsPane`
//  (SettingsView+TVComponents), so this page is iOS / macOS / visionOS only.
//

import SwiftUI

#if !os(tvOS)

    struct SportsSettingsView: View {
        @AppStorage(SportsSyncService.hideScoresKey) private var hideScores = false
        @State private var sync = SportsSyncService.shared
        @State private var showingManageTeams = false

        var body: some View {
            Form {
                teamsSection
                scoresSection
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

        private var scoresSection: some View {
            Section {
                Toggle("Hide Scores", isOn: $hideScores)
            } footer: {
                Text("Fixture cards and game details leave out scores and results, along with the match timeline and stats.")
            }
        }

        private var refreshSection: some View {
            Section {
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
                Text("Sports Data")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fixtures, live scores and standings refresh whenever you open Home or the Sports tab, and every minute while they're on screen.")
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

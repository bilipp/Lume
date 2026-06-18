//
//  TVSportPreferencesView.swift
//  Lume
//
//  The tvOS Sports settings pane: switch football leagues/cups on or off and
//  follow individual teams from a browsed league. Mirrors the look of the other
//  tvOS settings panes (see SettingsView+TVHome). Selections are stored as
//  `SportFavorite`s, the same as the iOS/macOS `SportPreferencesView`.
//

import SwiftData
import SwiftUI

#if os(tvOS)

    struct TVSportPreferencesView: View {
        @Environment(\.modelContext) private var modelContext
        @Query(sort: \SportFavorite.addedAt) private var favorites: [SportFavorite]
        @State private var browser = SportTeamBrowser()
        @State private var browseLeagueID = SportCatalog.defaultTeamLeagueID
        @State private var teamQuery = ""
        @State private var searchResults: [SportTeam] = []
        @State private var isSearching = false

        private var isSearchActive: Bool {
            !teamQuery.trimmingCharacters(in: .whitespaces).isEmpty
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 36) {
                leaguesSection
                teamsSection
            }
            .task(id: browseLeagueID) {
                if let league = SportCatalog.league(id: browseLeagueID) {
                    await browser.load(league: league)
                }
            }
            .task(id: teamQuery) {
                await runSearch()
            }
        }

        // MARK: - Leagues

        private var leaguesSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Leagues & Cups")

                VStack(spacing: 2) {
                    ForEach(SportCatalog.leagues) { league in
                        toggleRow(
                            title: league.name,
                            subtitle: league.region,
                            isOn: isFavorite(.league, externalID: league.id)
                        ) {
                            toggle(.league, externalID: league.id, name: league.name)
                        }
                    }
                }

                Text("Pick the competitions you follow. Their upcoming matches appear on Home and link to the channel that carries them.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 6)
            }
        }

        // MARK: - Teams

        private var teamsSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Teams")

                TextField("Search teams", text: $teamQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: TVSettingsMetrics.rowFontSize))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.vertical, TVSettingsMetrics.rowVPadding)
                    .background(
                        RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )

                if isSearchActive {
                    searchResultList
                } else {
                    browseControl
                    teamList
                }
            }
        }

        private var browseControl: some View {
            Button {
                browseLeagueID = nextLeagueID(after: browseLeagueID)
            } label: {
                HStack {
                    Text("Browse League")
                    Spacer(minLength: 16)
                    Text(SportCatalog.league(id: browseLeagueID)?.name ?? "")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: TVSettingsMetrics.rowFontSize))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }

        @ViewBuilder
        private var teamList: some View {
            if browser.isLoading {
                tvProgress("Loading teams…")
            } else if browser.failed {
                tvHint("Couldn't load teams. Check your connection and try again.")
            } else if browser.teams.isEmpty {
                tvHint("No teams found for this league.")
            } else {
                teamRows(browser.teams)
            }
        }

        @ViewBuilder
        private var searchResultList: some View {
            if isSearching {
                tvProgress("Searching…")
            } else if searchResults.isEmpty {
                tvHint("No teams found.")
            } else {
                teamRows(searchResults)
            }
        }

        private func teamRows(_ teams: [SportTeam]) -> some View {
            VStack(spacing: 2) {
                ForEach(teams) { team in
                    toggleRow(
                        title: team.name,
                        subtitle: team.leagueName.flatMap { $0 == "_No League Soccer" ? nil : $0 },
                        isOn: isFavorite(.team, externalID: team.id)
                    ) {
                        toggle(.team, externalID: team.id, name: team.name, badgeURL: team.badgeURL?.absoluteString)
                    }
                }
            }
        }

        private func tvProgress(_ text: LocalizedStringKey) -> some View {
            HStack(spacing: 12) {
                ProgressView()
                Text(text).foregroundStyle(.secondary)
            }
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            .padding(.top, 8)
        }

        // MARK: - Search

        private func runSearch() async {
            let query = teamQuery.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else {
                searchResults = []
                isSearching = false
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            isSearching = true
            defer { isSearching = false }
            searchResults = await (try? SportsDBClient.shared.searchTeams(query)) ?? []
        }

        // MARK: - Rows

        private func toggleRow(title: String, subtitle: String?, isOn: Bool, action: @escaping () -> Void) -> some View {
            HStack(spacing: 16) {
                Button(action: action) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .accessibilityLabel(Text(verbatim: title))
                .accessibilityValue(isOn ? Text("On") : Text("Off"))

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(.system(size: TVSettingsMetrics.rowFontSize))
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(isOn ? .primary : .secondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            .padding(.vertical, TVSettingsMetrics.rowVPadding)
            .background(
                RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }

        private func tvHint(_ text: LocalizedStringKey) -> some View {
            Text(text)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 8)
        }

        // MARK: - Helpers

        private func nextLeagueID(after id: String) -> String {
            let ids = SportCatalog.leagues.map(\.id)
            guard let index = ids.firstIndex(of: id) else { return ids.first ?? "" }
            return ids[(index + 1) % ids.count]
        }

        private func isFavorite(_ kind: SportFavoriteKind, externalID: String) -> Bool {
            favorites.contains { $0.kind == kind && $0.externalID == externalID }
        }

        private func toggle(_ kind: SportFavoriteKind, externalID: String, name: String, badgeURL: String? = nil) {
            if let existing = favorites.first(where: { $0.kind == kind && $0.externalID == externalID }) {
                modelContext.delete(existing)
            } else {
                modelContext.insert(SportFavorite(kind: kind, externalID: externalID, name: name, badgeURL: badgeURL))
            }
            try? modelContext.save()
        }
    }

#endif

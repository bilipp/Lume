//
//  SportPreferencesView.swift
//  Lume
//
//  Settings for the Home "Upcoming Matches" row: pick the football leagues/cups
//  and teams to follow. Selections are stored as `SportFavorite`s and drive
//  which fixtures the row fetches. Football-only for now.
//
//  This file holds the shared team-browser model and the iOS/macOS screen; the
//  tvOS pane lives in `TVSportPreferencesView`.
//

import SwiftData
import SwiftUI

/// Loads a league's teams from TheSportsDB for the "Teams" picker, caching the
/// last league so re-selecting it doesn't refetch.
@MainActor
@Observable
final class SportTeamBrowser {
    private(set) var teams: [SportTeam] = []
    private(set) var isLoading = false
    private(set) var failed = false
    private var loadedLeagueID: String?

    private let client: SportsDBClient

    init(client: SportsDBClient = .shared) {
        self.client = client
    }

    func load(league: SportLeague) async {
        guard league.id != loadedLeagueID else { return }
        isLoading = true
        failed = false
        defer { isLoading = false }
        do {
            teams = try await client.teams(leagueName: league.searchName)
            loadedLeagueID = league.id
        } catch {
            teams = []
            failed = true
        }
    }
}

#if !os(tvOS)

    struct SportPreferencesView: View {
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
            List {
                if isSearchActive {
                    searchResultsSection
                } else {
                    leaguesSection
                    teamsSection
                }
            }
            .platformNavigationTitle("Sports")
            .searchable(text: $teamQuery, prompt: "Search teams")
            .task(id: browseLeagueID) {
                if let league = SportCatalog.league(id: browseLeagueID) {
                    await browser.load(league: league)
                }
            }
            .task(id: teamQuery) {
                await runSearch()
            }
        }

        private var leaguesSection: some View {
            Section {
                ForEach(SportCatalog.leagues) { league in
                    Button {
                        toggle(.league, externalID: league.id, name: league.name)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(league.name)
                                    .foregroundStyle(.primary)
                                Text(league.region)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isFavorite(.league, externalID: league.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("Leagues & Cups")
            } footer: {
                Text("Pick the competitions you follow. Upcoming matches appear on Home and link to the channel that carries them.")
            }
        }

        private var teamsSection: some View {
            Section {
                Picker("League", selection: $browseLeagueID) {
                    ForEach(SportCatalog.leagues) { league in
                        Text(league.name).tag(league.id)
                    }
                }

                if browser.isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading teams…")
                            .foregroundStyle(.secondary)
                    }
                } else if browser.failed {
                    Text("Couldn't load teams. Check your connection and try again.")
                        .foregroundStyle(.secondary)
                } else if browser.teams.isEmpty {
                    Text("No teams found for this league.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(browser.teams, content: teamRow)
                }
            } header: {
                Text("Teams")
            } footer: {
                Text("Browse a league, or search above to follow any team — including ones beyond this list.")
            }
        }

        private var searchResultsSection: some View {
            Section {
                if isSearching {
                    HStack {
                        ProgressView()
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                } else if searchResults.isEmpty {
                    Text("No teams found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(searchResults, content: teamRow)
                }
            } header: {
                Text("Teams")
            }
        }

        private func teamRow(_ team: SportTeam) -> some View {
            Button {
                toggle(.team, externalID: team.id, name: team.name, badgeURL: team.badgeURL?.absoluteString)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(team.name)
                            .foregroundStyle(.primary)
                        if let league = team.leagueName, !league.isEmpty, league != "_No League Soccer" {
                            Text(league)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if isFavorite(.team, externalID: team.id) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
        }

        // MARK: - Search

        private func runSearch() async {
            let query = teamQuery.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else {
                searchResults = []
                isSearching = false
                return
            }
            // Debounce so we don't fire a request on every keystroke.
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            isSearching = true
            defer { isSearching = false }
            searchResults = await (try? SportsDBClient.shared.searchTeams(query)) ?? []
        }

        // MARK: - Favorites

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

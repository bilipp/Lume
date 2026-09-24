//
//  LeagueTeamsView.swift
//  Lume
//
//  The team list for one league, drilled into from the Manage Teams browser.
//  Teams come from the in-memory `SportsStore` cache; when the league has not
//  been fetched yet they are pulled once from the `SportsDataProvider` and merged
//  back into the store (crests and colours only — fixtures and standings stay
//  untouched). Each row toggles a ★ follow through `SportsFollowService`. Team
//  names are shown verbatim, never localised.
//

import SwiftUI

struct LeagueTeamsView: View {
    let league: SportsLeague
    var provider: any SportsDataProvider = ESPNClient.shared

    @State private var store = SportsStore.shared
    @State private var follows = SportsFollowService.shared
    @State private var teams: [SportsTeam] = []
    @State private var isLoading = false

    var body: some View {
        List {
            if teams.isEmpty {
                Section {
                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading teams…").foregroundStyle(.secondary)
                        }
                    } else {
                        ContentUnavailableView(
                            "No Teams",
                            systemImage: "person.3",
                            description: Text("This league's teams aren't available right now.")
                        )
                    }
                }
            } else {
                ForEach(teams) { team in
                    teamRow(team)
                }
            }
        }
        .navigationTitle(league.name)
        .task { await loadTeams() }
    }

    private func teamRow(_ team: SportsTeam) -> some View {
        Button {
            toggleTeam(team)
        } label: {
            HStack(spacing: 12) {
                let following = follows.isFollowing(team.id)
                Image(systemName: following ? "star.fill" : "star")
                    .foregroundStyle(following ? Color.yellow : Color.secondary)
                TeamCrest(team: team, size: 26)
                Text(team.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            follows.isFollowing(team.id)
                ? Text("Unfollow \(team.name)")
                : Text("Follow \(team.name)")
        )
    }

    private func toggleTeam(_ team: SportsTeam) {
        follows.toggle(team.id, kind: .team)
    }

    /// Loads the league's teams from the store, fetching once from the provider
    /// (and merging the roster back into the store) when the cache is empty.
    private func loadTeams() async {
        if let cached = store.snapshot(for: league.id)?.teams, !cached.isEmpty {
            teams = cached.sorted { $0.name < $1.name }
            return
        }
        isLoading = true
        defer { isLoading = false }
        let fetched = await (try? provider.teams(league: league)) ?? []
        guard !fetched.isEmpty else { return }
        store.mergeTeams(fetched, for: league.id)
        teams = fetched.sorted { $0.name < $1.name }
    }
}

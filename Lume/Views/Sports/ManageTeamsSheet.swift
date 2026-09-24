//
//  ManageTeamsSheet.swift
//  Lume
//
//  Follow and reorder leagues and teams. The "Following" list reorders the
//  active profile's follows (the first few lead the Home shelf) and unfollows
//  with a ★ tap; a search field filters the whole catalogue and every cached
//  team; below it the curated leagues are grouped by region, each with a ★
//  toggle and a chevron drilling into `LeagueTeamsView`. All follow reads/writes
//  go through `SportsFollowService`; team lookups through `SportsStore`.
//

import SwiftUI

struct ManageTeamsSheet: View {
    @State private var follows = SportsFollowService.shared
    @State private var store = SportsStore.shared
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    searchResults
                } else {
                    followingSection
                    browseSections
                }
            }
            .searchable(text: $searchText, prompt: Text("Search every league"))
            .platformNavigationTitle("Manage Teams")
            .toolbar { toolbarContent }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
        #if os(iOS) || os(visionOS)
            if !follows.follows.isEmpty {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        #endif
    }

    // MARK: - Following

    @ViewBuilder
    private var followingSection: some View {
        if follows.follows.isEmpty {
            Section {
                ContentUnavailableView(
                    "No Teams Followed",
                    systemImage: "star",
                    description: Text("Follow leagues and teams below to build your Sports Hub.")
                )
            }
        } else {
            Section {
                ForEach(follows.follows) { follow in
                    followingRow(follow)
                }
                .onMove { source, destination in
                    follows.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    for index in offsets {
                        follows.unfollow(follows.follows[index].key)
                    }
                }
            } header: {
                Text("Following")
            } footer: {
                Text("Drag to reorder — the first few lead the Home shelf.")
            }
        }
    }

    private func followingRow(_ follow: SportsFollow) -> some View {
        HStack(spacing: 12) {
            followingIcon(follow)
            VStack(alignment: .leading, spacing: 1) {
                Text(followName(follow))
                    .lineLimit(1)
                let subtitle = followSubtitle(follow)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button {
                follows.unfollow(follow.key)
            } label: {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Unfollow \(followName(follow))"))
        }
    }

    @ViewBuilder
    private func followingIcon(_ follow: SportsFollow) -> some View {
        if follow.kind == .team, let team = store.team(by: follow.key) {
            TeamCrest(team: team, size: 24)
        } else {
            Image(systemName: follow.kind == .league ? "trophy.fill" : "star.fill")
                .foregroundStyle(.secondary)
                .frame(width: 24)
        }
    }

    // MARK: - Browse

    private var browseSections: some View {
        ForEach(regionsInOrder, id: \.self) { region in
            Section(header: Text(region.displayName)) {
                ForEach(SportsCatalog.leagues(in: region)) { league in
                    leagueRow(league)
                }
            }
        }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchResults: some View {
        let leagues = matchingLeagues
        let teams = matchingTeams
        if leagues.isEmpty, teams.isEmpty {
            Section {
                ContentUnavailableView.search(text: searchText)
            }
        } else {
            if !leagues.isEmpty {
                Section("Leagues") {
                    ForEach(leagues) { leagueRow($0) }
                }
            }
            if !teams.isEmpty {
                Section("Teams") {
                    ForEach(teams) { teamRow($0) }
                }
            }
        }
    }

    // MARK: - Rows

    private func leagueRow(_ league: SportsLeague) -> some View {
        HStack(spacing: 12) {
            followButton(isOn: follows.isFollowing(league.id), name: league.name) {
                toggleLeague(league)
            }
            NavigationLink {
                LeagueTeamsView(league: league)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(league.name).lineLimit(1)
                    Text(league.abbreviation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func teamRow(_ team: SportsTeam) -> some View {
        HStack(spacing: 12) {
            followButton(isOn: follows.isFollowing(team.id), name: team.name) {
                toggleTeam(team)
            }
            TeamCrest(team: team, size: 24)
            Text(team.name).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func followButton(isOn: Bool, name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isOn ? "star.fill" : "star")
                .foregroundStyle(isOn ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? Text("Unfollow \(name)") : Text("Follow \(name)"))
    }

    // MARK: - Follow actions

    private func toggleLeague(_ league: SportsLeague) {
        follows.toggle(league.id, kind: .league)
    }

    private func toggleTeam(_ team: SportsTeam) {
        follows.toggle(team.id, kind: .team)
    }

    // MARK: - Naming

    private func followName(_ follow: SportsFollow) -> String {
        switch follow.kind {
        case .league:
            SportsCatalog.league(id: follow.key)?.name ?? follow.key
        case .team:
            store.team(by: follow.key)?.name ?? follow.key
        }
    }

    private func followSubtitle(_ follow: SportsFollow) -> String {
        switch follow.kind {
        case .league:
            SportsCatalog.league(id: follow.key).map { String(localized: $0.region.displayName) } ?? ""
        case .team:
            leagueName(forTeamKey: follow.key)
        }
    }

    private func leagueName(forTeamKey key: String) -> String {
        guard let leagueId = SportsHubView.leagueId(fromTeamKey: key) else { return "" }
        return SportsCatalog.league(id: leagueId)?.name ?? ""
    }

    // MARK: - Derived data

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The catalogue's browse order with the viewer's home sections lifted to
    /// the top.
    private var regionsInOrder: [SportsRegion] {
        SportsCatalog.browseRegions(for: Locale.current.region)
    }

    private var matchingLeagues: [SportsLeague] {
        let query = searchText
        return SportsCatalog.leagues.filter { league in
            Self.matches(query, league.name, league.abbreviation)
        }
    }

    private var matchingTeams: [SportsTeam] {
        let query = searchText
        var seen: Set<String> = []
        var result: [SportsTeam] = []
        for team in store.snapshots.values.flatMap(\.teams)
            where Self.matches(query, team.name, team.shortName, team.abbreviation) && seen.insert(team.id).inserted
        {
            result.append(team)
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func matches(_ query: String, _ candidates: String...) -> Bool {
        let needle = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return candidates.contains {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(needle)
        }
    }
}

// MARK: - Region titles

nonisolated extension SportsRegion {
    /// The section title for the Manage Teams browser. Region buckets are UI
    /// grouping, so their names are localised here (team and league names are not).
    var displayName: LocalizedStringResource {
        switch self {
        case .germany: "Germany"
        case .ukAndIreland: "UK & Ireland"
        case .spain: "Spain"
        case .italy: "Italy"
        case .france: "France"
        case .netherlands: "Netherlands"
        case .portugal: "Portugal"
        case .europe: "Europe"
        case .clubCompetitions: "International Club Cups"
        case .international: "National Teams"
        case .womensFootball: "Women's Football"
        case .americas: "Americas"
        case .restOfWorld: "Rest of World"
        case .americanFootball: "American Football"
        case .basketball: "Basketball"
        case .iceHockey: "Ice Hockey"
        case .baseball: "Baseball"
        case .rugby: "Rugby"
        case .australianFootball: "Australian Football"
        case .cricket: "Cricket"
        case .tennis: "Tennis"
        case .lacrosse: "Lacrosse"
        case .motorsport: "Motorsport"
        case .combat: "Combat Sports"
        }
    }
}

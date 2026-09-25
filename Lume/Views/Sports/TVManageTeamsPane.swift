//
//  TVManageTeamsPane.swift
//  Lume
//
//  The tvOS Manage Teams surface, presented from the Sports Hub and the Settings
//  sports pane. The phone sheet's `List` + `.searchable` + `EditButton` do not
//  read on a remote, so this is a purpose-built 10-foot screen: a "Following"
//  list reordered with the shared pick-up/place gesture (`TVReorderableContentList`)
//  and unfollowed with a ★ tap, then the curated leagues grouped by region, each
//  with a ★ toggle and an in-place drill-in to its teams. All follow reads/writes
//  go through `SportsFollowService`; team lookups through `SportsStore`. Team and
//  league names are shown verbatim, never localised.
//

#if os(tvOS)

    import SwiftUI

    /// `TVReorderableContentList` rows only need a stable string id.
    extension SportsFollow: ReorderableRowItem {}

    struct TVManageTeamsPane: View {
        @State private var follows = SportsFollowService.shared
        @State private var store = SportsStore.shared
        @State private var selectedLeague: SportsLeague?
        @State private var isReordering = false

        @Environment(\.dismiss) private var dismiss

        var body: some View {
            Group {
                if let selectedLeague {
                    TVLeagueTeamsPane(league: selectedLeague) { self.selectedLeague = nil }
                } else {
                    mainPane
                }
            }
            .tvSettingsBackground()
        }

        // MARK: - Main pane

        private var mainPane: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        Text("Manage Teams")
                            .font(.system(size: TVSettingsMetrics.titleFontSize, weight: .bold))
                            .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                        followingSection(proxy: proxy)
                        browseSections
                    }
                    .frame(maxWidth: TVSettingsMetrics.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 60)
                    .padding(.vertical, 72)
                }
                .focusSection()
            }
            // At rest, Menu leaves the pane; while a row is lifted the reorder list
            // owns Menu (cancel), so it never reaches here.
            .onExitCommand { if !isReordering { dismiss() } }
        }

        // MARK: - Following

        private func followingSection(proxy: ScrollViewProxy) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Following")

                if follows.follows.isEmpty {
                    Text("Follow leagues and teams below to build your Sports Hub.")
                        .tvSettingsSecondaryText()
                } else {
                    if isReordering {
                        Text("Move up or down to position, then select to place. Press Menu to cancel.")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    }

                    TVReorderableContentList(
                        items: follows.follows,
                        title: followName,
                        isHidden: { _ in false },
                        onToggleHidden: { follows.unfollow($0.key) },
                        onCommitOrder: { follows.setOrder($0) },
                        isReordering: $isReordering,
                        scrollProxy: proxy,
                        toggleImage: { _ in "star.fill" },
                        toggleAccessibility: { _, name in String(localized: "Unfollow \(name)") }
                    )

                    Text("Select a row to lift it, then move up or down and select again to place — the first few lead the Home shelf.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 4)
                }
            }
        }

        // MARK: - Browse

        private var browseSections: some View {
            ForEach(regionsInOrder, id: \.self) { region in
                VStack(alignment: .leading, spacing: 8) {
                    regionHeader(region)
                    ForEach(SportsCatalog.leagues(in: region)) { league in
                        leagueRow(league)
                    }
                }
                // Keep the browse controls from stealing focus mid-move.
                .disabled(isReordering)
                .opacity(isReordering ? 0.35 : 1)
            }
        }

        private func regionHeader(_ region: SportsRegion) -> some View {
            Text(region.displayName)
                .textCase(.uppercase)
                .font(.system(size: TVSettingsMetrics.labelFontSize, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 12)
                .padding(.bottom, 4)
        }

        private func leagueRow(_ league: SportsLeague) -> some View {
            let following = follows.isFollowing(league.id)
            return HStack(spacing: 14) {
                Button {
                    toggleLeague(league)
                } label: {
                    Image(systemName: following ? "star.fill" : "star")
                        .foregroundStyle(following ? .yellow : .white)
                }
                .buttonStyle(TVContentIconButtonStyle())
                .accessibilityLabel(following ? Text("Unfollow \(league.name)") : Text("Follow \(league.name)"))

                Button {
                    selectedLeague = league
                } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: league.name)
                                .lineLimit(1)
                            Text(verbatim: league.abbreviation)
                                .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text("Teams")
                            .font(.system(size: TVSettingsMetrics.secondaryFontSize, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 22, weight: .semibold))
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
            }
        }

        // MARK: - Actions

        private func toggleLeague(_ league: SportsLeague) {
            follows.toggle(league.id, kind: .league)
        }

        private func followName(_ follow: SportsFollow) -> String {
            switch follow.kind {
            case .league:
                SportsCatalog.league(id: follow.key)?.name ?? follow.key
            case .team:
                store.team(by: follow.key)?.name ?? follow.key
            }
        }

        /// The catalogue's browse order with the viewer's home sections lifted to
        /// the top.
        private var regionsInOrder: [SportsRegion] {
            SportsCatalog.browseRegions(for: Locale.current.region)
        }
    }

    // MARK: - League teams (in-place drill-in)

    /// The team list for one league, shown in place of the main pane. Mirrors
    /// `LeagueTeamsView` (iOS) with tvOS-sized, full-width focus rows. Menu returns
    /// to the browser.
    private struct TVLeagueTeamsPane: View {
        let league: SportsLeague
        let onBack: () -> Void
        var provider: any SportsDataProvider = ESPNClient.shared

        @State private var store = SportsStore.shared
        @State private var follows = SportsFollowService.shared
        @State private var teams: [SportsTeam] = []
        @State private var isLoading = false

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: league.name)
                        .font(.system(size: TVSettingsMetrics.titleFontSize, weight: .bold))
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.bottom, 12)

                    if teams.isEmpty {
                        if isLoading {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Loading teams…").foregroundStyle(.secondary)
                            }
                            .font(.system(size: TVSettingsMetrics.statusFontSize))
                            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        } else {
                            Text("This league's teams aren't available right now.")
                                .tvSettingsSecondaryText()
                        }
                    } else {
                        ForEach(teams) { team in
                            teamRow(team)
                        }
                    }
                }
                .frame(maxWidth: TVSettingsMetrics.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 60)
                .padding(.vertical, 72)
            }
            .focusSection()
            .onExitCommand(perform: onBack)
            .task { await loadTeams() }
        }

        private func teamRow(_ team: SportsTeam) -> some View {
            let following = follows.isFollowing(team.id)
            return Button {
                toggleTeam(team)
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: following ? "star.fill" : "star")
                        .foregroundStyle(following ? .yellow : .secondary)
                        .font(.system(size: 24, weight: .semibold))
                    TeamCrest(team: team, size: 34)
                        .accessibilityHidden(true)
                    Text(verbatim: team.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
            .accessibilityLabel(following ? Text("Unfollow \(team.name)") : Text("Follow \(team.name)"))
        }

        private func toggleTeam(_ team: SportsTeam) {
            follows.toggle(team.id, kind: .team)
        }

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

#endif

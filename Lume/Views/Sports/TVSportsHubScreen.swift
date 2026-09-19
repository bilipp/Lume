//
//  TVSportsHubScreen.swift
//  Lume
//
//  The tvOS Sports Hub. The phone hub's segmented control and toolbar do not
//  read on a remote, so this is a purpose-built 10-foot screen: a focusable pill
//  filter (Yesterday / Today / Upcoming) beside a scope Menu and a Manage Teams
//  button, then full-width horizontal rails of `TVFixtureLogoCard`s, one focus
//  section per day. It shares the hub's data plumbing — `SportsStore` snapshots,
//  `SportsFollowService` follows, off-main `SportsChannelResolver` — and reuses
//  `SportsHubView`'s static date/assembly helpers so the two hubs stay in step.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    /// Focus targets on the hub, so Menu (exit) from a card can return focus to
    /// the filter row rather than dropping to the tab bar mid-browse.
    private enum TVSportsFocus: Hashable {
        case segment(SportsHubSegment)
        case manage
        case card(String)
    }

    struct TVSportsHubScreen: View {
        @Environment(\.modelContext) private var modelContext
        @Environment(\.contentRestriction) private var restriction

        @State private var premium = PremiumManager.shared
        @State private var store = SportsStore.shared
        @State private var follows = SportsFollowService.shared
        @State private var epg = EPGSyncService.shared

        @State private var scope: SportsHubScope = .myTeams
        @State private var segment: SportsHubSegment = .today
        @State private var resolved: [String: [ResolvedChannel]] = [:]
        @State private var selectedFixture: SportsFixture?
        @State private var showManageTeams = false
        @State private var showPaywall = false
        @State private var playingMedia: PlayableMedia?

        @FocusState private var focus: TVSportsFocus?

        var body: some View {
            Group {
                if premium.isPremium {
                    hub
                } else {
                    lockedState
                }
            }
            .sheet(isPresented: $showManageTeams) { TVManageTeamsPane() }
            .fullScreenCover(item: $selectedFixture) { fixture in
                TVGameDetailSheet(fixture: fixture, resolved: resolved[fixture.id] ?? [], onWatch: watch)
            }
            .fullScreenCover(item: $playingMedia) { media in
                FullScreenPlayerView(media: media)
            }
            .paywall(isPresented: $showPaywall, highlight: .sportsHub)
            .onAppear(perform: onAppear)
            .onDisappear { SportsSyncService.shared.endLivePolling() }
        }

        // MARK: - Hub

        @ViewBuilder
        private var hub: some View {
            if follows.follows.isEmpty {
                onboardingState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    filterBar
                    content
                }
            }
        }

        /// One row of three controls in one pill chrome: the scope menu (which
        /// reads as the screen's title, Strand-style), the day filter and Manage
        /// Teams — same height, same corner radius, same rest wash.
        private var filterBar: some View {
            HStack(spacing: 24) {
                scopeMenu
                segmentedControl
                Spacer(minLength: 24)
                manageButton
            }
            .padding(.horizontal, 60)
            .padding(.top, 28)
            .padding(.bottom, 28)
            .focusSection()
        }

        private var content: some View {
            Group {
                if groups.isEmpty {
                    noGamesState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 40) {
                            if epg.isSyncing {
                                hintRow("Updating guide…", icon: "arrow.triangle.2.circlepath")
                            }
                            if store.refreshError {
                                hintRow("Scores unavailable — showing your saved data.", icon: "wifi.slash")
                            }
                            ForEach(groups) { group in
                                section(for: group)
                            }
                        }
                        .padding(.vertical, 20)
                    }
                    .scrollClipDisabled()
                    .defaultFocus($focus, firstCardFocus)
                    .onExitCommand { returnFocusToFilter() }
                }
            }
            .task(id: resolveKey) { await runResolve() }
        }

        // MARK: - Filter controls

        private var segmentedControl: some View {
            HStack(spacing: 6) {
                ForEach(SportsHubSegment.allCases) { segment in
                    segmentButton(segment)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.08))
            )
        }

        private func segmentButton(_ value: SportsHubSegment) -> some View {
            let isActive = segment == value
            let isItemFocused = focus == .segment(value)
            return Button {
                segment = value
            } label: {
                TVSportsPillLabel(
                    title: value.title,
                    font: .headline,
                    isFocused: isItemFocused,
                    isActive: isActive,
                    horizontalPadding: 28,
                    verticalPadding: 14,
                    cornerRadius: 12
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.04))
            .focused($focus, equals: .segment(value))
            .animation(.easeOut(duration: 0.18), value: isItemFocused)
        }

        private var scopeMenu: some View {
            Menu {
                Picker("Scope", selection: $scope) {
                    Label("My Teams", systemImage: "star.fill").tag(SportsHubScope.myTeams)
                    ForEach(followedLeagues) { league in
                        Text(verbatim: league.name).tag(SportsHubScope.league(league.id))
                    }
                }
            } label: {
                TVSportsPillChrome {
                    HStack(spacing: 10) {
                        Text(verbatim: scopeTitle).font(.headline)
                        Image(systemName: "chevron.down").font(.callout.weight(.bold))
                    }
                }
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.04))
        }

        private var manageButton: some View {
            Button {
                showManageTeams = true
            } label: {
                TVSportsPillChrome {
                    Label("Manage Teams", systemImage: "person.2.badge.plus")
                        .font(.headline)
                }
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.04))
            .focused($focus, equals: .manage)
        }

        // MARK: - Sections

        private func section(for group: SportsFixtureGroup) -> some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    if let logoURL = group.logoURL {
                        CachedAsyncImage(url: logoURL, maxPixelSize: 40) { phase in
                            if case let .success(image) = phase {
                                image.resizable().scaledToFit()
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                    }
                    Text(verbatim: group.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 60)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 24) {
                        ForEach(group.fixtures) { fixture in
                            TVFixtureLogoCard(fixture: fixture) { selectedFixture = fixture }
                                .focused($focus, equals: .card(fixture.id))
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 8)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }

        // MARK: - States

        private var onboardingState: some View {
            fullScreenState(
                title: "Follow Your Teams",
                message: "Add leagues and teams to see fixtures, live scores and standings, with one tap to the channel carrying the game."
            ) {
                Button {
                    showManageTeams = true
                } label: {
                    Label("Manage Teams", systemImage: "person.2.badge.plus")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 44)
                        .padding(.vertical, 20)
                }
                .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
            }
        }

        private var lockedState: some View {
            fullScreenState(
                title: PremiumFeature.sportsHub.title,
                message: PremiumFeature.sportsHub.subtitle
            ) {
                Button {
                    showPaywall = true
                } label: {
                    Text("Unlock Sports Hub")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 44)
                        .padding(.vertical, 20)
                }
                .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
            }
        }

        private var noGamesState: some View {
            VStack(spacing: 24) {
                Text("No games")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                if !emptyChips.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(emptyChips, id: \.self) { chip in
                            Text(verbatim: chip)
                                .font(.headline)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                                .background(Capsule().fill(.white.opacity(0.1)))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private func fullScreenState(
            title: LocalizedStringResource,
            message: LocalizedStringResource,
            @ViewBuilder action: () -> some View
        ) -> some View {
            VStack(spacing: 24) {
                Image(systemName: "sportscourt")
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.5))
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 820)
                action()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private func hintRow(_ text: LocalizedStringKey, icon: String) -> some View {
            Label(text, systemImage: icon)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 60)
        }

        // MARK: - Focus

        private var firstCardFocus: TVSportsFocus? {
            groups.first?.fixtures.first.map { TVSportsFocus.card($0.id) }
        }

        private func returnFocusToFilter() {
            Task { @MainActor in focus = .segment(segment) }
        }

        // MARK: - Lifecycle

        private func onAppear() {
            store.loadCached(leagueIds: displayLeagueIds)
            SportsSyncService.shared.syncIfDue()
            SportsSyncService.shared.refreshMissing()
            SportsSyncService.shared.beginLivePolling()
            Task { await EPGSyncService.shared.refreshIfMissingSubtitles() }
        }

        private var resolveKey: String {
            visibleFixtures.map(\.id).joined(separator: ",") + "|" + String(epg.isSyncing)
        }

        private func runResolve() async {
            let fixtures = visibleFixtures
            guard !fixtures.isEmpty else {
                resolved = [:]
                return
            }
            resolved = await SportsChannelResolver.resolve(
                container: modelContext.container,
                fixtures: fixtures,
                now: Date(),
                restriction: restriction
            )
        }

        // MARK: - Playback

        private func watch(_ channel: ResolvedChannel) {
            guard let media = SportsPlayback.media(for: channel, in: modelContext) else { return }

            let hadSheet = selectedFixture != nil
            selectedFixture = nil
            if hadSheet {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    playingMedia = media
                }
            } else {
                playingMedia = media
            }
        }
    }

    private extension TVSportsHubScreen {
        // MARK: - Follow

        private func isFollowed(_ team: SportsTeam) -> Bool {
            follows.isFollowing(team.id)
        }

        // MARK: - Fixture assembly

        /// The shared selection/grouping rules; the tvOS hub keeps only its chrome.
        private var grouping: SportsHubGrouping {
            SportsHubGrouping(scope: scope, segment: segment, follows: follows.follows, store: store)
        }

        private var displayLeagueIds: [String] {
            grouping.displayLeagueIds
        }

        private var followedLeagues: [SportsLeague] {
            grouping.followedLeagues
        }

        private var visibleFixtures: [SportsFixture] {
            grouping.visibleFixtures
        }

        private var groups: [SportsFixtureGroup] {
            grouping.groups
        }

        private var emptyChips: [String] {
            grouping.emptyChips
        }

        private var scopeTitle: String {
            grouping.scopeTitle
        }
    }
#endif

//
//  TVSportsHubScreen.swift
//  Lume
//
//  The tvOS Sports Hub. The phone hub's segmented control and toolbar do not
//  read on a remote, so this is a purpose-built 10-foot screen: one scrolling
//  page whose header is the scope menu drawn as the page title, a compact
//  Yesterday / Today / Upcoming switch and an icon-only Manage Teams button,
//  then full-width horizontal rails of `TVFixtureLogoCard`s, one focus section
//  per group. The header scrolls with the page — a pinned bar over an unclipped
//  scroll view had the cards sliding underneath it. It shares the hub's data
//  plumbing — `SportsStore` snapshots, `SportsFollowService` follows, off-main
//  `SportsChannelResolver` — and reuses `SportsHubView`'s static date/assembly
//  helpers so the two hubs stay in step.
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
        /// Playback queued behind the dismissing detail cover; see `watch`.
        @State private var pendingMedia: PlayableMedia?

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
            .fullScreenCover(item: $selectedFixture, onDismiss: presentPendingMedia) { fixture in
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
                content
            }
        }

        /// The whole hub is one scrolling page so the header can never sit over
        /// the cards: title-style scope menu on the left, the day switch and the
        /// Manage Teams button on the right, then the rails.
        private var content: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 36) {
                    header
                    if groups.isEmpty {
                        noGamesState
                    } else {
                        ForEach(groups) { group in
                            section(for: group)
                        }
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .scrollClipDisabled()
            .defaultFocus($focus, firstCardFocus)
            .onExitCommand { returnFocusToFilter() }
            .task(id: resolveKey) { await runResolve() }
        }

        // MARK: - Header

        /// The scope menu reads as the page title; the controls to its right
        /// stay quiet at rest — only the active day carries a fill — so the row
        /// reads as a heading, not a toolbar. Status hints sit under the title.
        private var header: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 24) {
                    scopeMenu
                    Spacer(minLength: 24)
                    segmentedControl
                    manageButton
                }
                if epg.isSyncing {
                    hintRow("Updating guide…", icon: "arrow.triangle.2.circlepath")
                }
                if store.refreshError {
                    hintRow("Scores unavailable — showing your saved data.", icon: "wifi.slash")
                }
            }
            .padding(.horizontal, 60)
            .focusSection()
        }

        // MARK: - Filter controls

        private var segmentedControl: some View {
            HStack(spacing: 4) {
                ForEach(SportsHubSegment.allCases) { segment in
                    segmentButton(segment)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.08))
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
                    font: .callout.weight(.semibold),
                    isFocused: isItemFocused,
                    isActive: isActive,
                    horizontalPadding: 22,
                    verticalPadding: 12,
                    cornerRadius: 12
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.03))
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
                TVSportsTitleChrome {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(verbatim: scopeTitle)
                            .font(.system(size: 34, weight: .bold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.02))
            .accessibilityLabel(Text(verbatim: scopeTitle))
        }

        private var manageButton: some View {
            Button {
                showManageTeams = true
            } label: {
                TVSportsCircleChrome {
                    Image(systemName: "person.2.badge.plus")
                        .font(.system(size: 26, weight: .semibold))
                }
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
            .focused($focus, equals: .manage)
            .accessibilityLabel(Text("Manage Teams"))
        }

        // MARK: - Sections

        /// The heading matches `HomeRow`'s — subheadline, bold, secondary — so
        /// the hub's rails read like every other rail on the tvOS Home.
        private func section(for group: SportsFixtureGroup) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if let logoURL = group.logoURL {
                        CachedAsyncImage(url: logoURL, maxPixelSize: 40) { phase in
                            if case let .success(image) = phase {
                                image.resizable().scaledToFit()
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                    }
                    Text(verbatim: group.title)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 60)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 24) {
                        ForEach(group.fixtures) { fixture in
                            TVFixtureLogoCard(fixture: fixture, showsLeagueMark: !group.isSingleLeague) {
                                selectedFixture = fixture
                            }
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
                Image(systemName: "sportscourt")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.35))
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
            .frame(maxWidth: .infinity, minHeight: 560)
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
                .foregroundStyle(.white.opacity(0.55))
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
            SportsSyncService.shared.catchUpIfStale()
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

            if selectedFixture != nil {
                // Presented from the detail cover's `onDismiss`: a cover put up
                // while another is still animating out is torn down and
                // re-presented, opening the stream twice and tripping the
                // provider's connection cap. See `presentPendingMedia`.
                pendingMedia = media
                selectedFixture = nil
            } else {
                playingMedia = media
            }
        }

        private func presentPendingMedia() {
            guard let media = pendingMedia else { return }
            pendingMedia = nil
            playingMedia = media
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

    /// The page-title chrome for the scope menu: bare white text at rest, a soft
    /// wash when focused. A solid white fill here would turn the heading into a
    /// button and shout over the cards.
    private struct TVSportsTitleChrome<Content: View>: View {
        @ViewBuilder var content: () -> Content
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            content()
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(isFocused ? 0.16 : 0))
                )
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }

    /// A round icon-only control that shares the pills' rest wash and white
    /// focus fill, for actions that need no label at rest.
    private struct TVSportsCircleChrome<Content: View>: View {
        @ViewBuilder var content: () -> Content
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            content()
                .foregroundStyle(isFocused ? .black : .white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1))))
        }
    }

#endif

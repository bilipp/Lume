//
//  SportsHubView.swift
//  Lume
//
//  The Sports Hub tab. Follow leagues and teams for fixtures, live scores and a
//  one-tap route to the channel carrying a live game. A Lume Pro feature: free
//  users see the locked state, premium users the hub.
//
//  Data comes from `SportsStore` (cached snapshots), the followed set from
//  `SportsFollowService`, and channel resolution from `SportsChannelResolver` —
//  run once per visible fixture set off the main thread, never per card. The
//  scope Menu switches between "My Teams" and a single followed league; the
//  segmented control walks Yesterday / Today / Upcoming.
//

import SwiftData
import SwiftUI

/// What the hub is scoped to: every followed league/team, or one league.
enum SportsHubScope: Hashable {
    case myTeams
    case league(String)
}

/// The time window the segmented control selects.
enum SportsHubSegment: String, CaseIterable, Identifiable {
    case yesterday
    case today
    case upcoming

    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
        case .yesterday: "Yesterday"
        case .today: "Today"
        case .upcoming: "Upcoming"
        }
    }
}

struct SportsHubView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @Environment(DeepLinkRouter.self) private var router: DeepLinkRouter?
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    @State private var premium = PremiumManager.shared
    @State private var store = SportsStore.shared
    @State private var follows = SportsFollowService.shared
    @State private var epg = EPGSyncService.shared

    @State private var scope: SportsHubScope = .myTeams
    @State private var segment: SportsHubSegment = .today
    @State private var resolved: [String: [ResolvedChannel]] = [:]
    @State private var selectedFixture: SportsFixture?
    @State private var pickerFixture: SportsFixture?
    @State private var showManageTeams = false
    @State private var showPaywall = false
    @State private var localPath = NavigationPath()
    #if os(iOS) || os(visionOS)
        @State private var playingMedia: PlayableMedia?
        /// Playback queued behind a dismissing sheet; see `present(_:afterSheet:)`.
        @State private var pendingMedia: PlayableMedia?
    #endif

    var body: some View {
        let fixtures = premium.isPremium ? visibleFixtures : []
        NavigationStack(path: pathBinding) {
            Group {
                if premium.isPremium {
                    hubContent(fixtures)
                } else {
                    lockedState
                }
            }
            .platformNavigationTitle("Sports")
            .hubInlineNavigationTitle()
            .navigationDestination(for: SportsLeague.self) { league in
                LeagueDetailView(league: league)
            }
            .toolbar { if premium.isPremium { hubToolbar } }
            .sheet(isPresented: $showManageTeams) { ManageTeamsSheet() }
            .sheet(item: $selectedFixture, onDismiss: presentPendingMedia) { fixture in
                GameDetailSheet(fixture: fixture, resolved: resolved[fixture.id] ?? [], onWatch: watch)
            }
            .sheet(item: $pickerFixture, onDismiss: presentPendingMedia) { fixture in
                ChannelPickerSheet(fixture: fixture, resolved: resolved[fixture.id] ?? [], onWatch: watch)
            }
            .paywall(isPresented: $showPaywall, highlight: .sportsHub)
            #if os(iOS) || os(visionOS)
                .fullScreenCover(item: $playingMedia) { media in
                    FullScreenPlayerView(media: media)
                }
            #endif
        }
        .onAppear(perform: onAppear)
        .onDisappear { SportsSyncService.shared.endLivePolling() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var hubToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                Picker("Scope", selection: $scope) {
                    Label("My Teams", systemImage: "star.fill").tag(SportsHubScope.myTeams)
                    ForEach(followedLeagues) { league in
                        Text(league.name).tag(SportsHubScope.league(league.id))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(scopeTitle).font(.headline)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showManageTeams = true
            } label: {
                Label("Manage Teams", systemImage: "person.2.badge.plus")
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func hubContent(_ fixtures: [SportsFixture]) -> some View {
        if follows.follows.isEmpty {
            SportsOnboardingCard { showManageTeams = true }
        } else {
            VStack(spacing: 0) {
                Picker("Range", selection: $segment) {
                    ForEach(SportsHubSegment.allCases) { segment in
                        Text(segment.title).tag(segment)
                    }
                }
                .hubSegmentedPickerStyle()
                .padding(.horizontal)
                .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if epg.isSyncing {
                            hint("Updating guide…", icon: "arrow.triangle.2.circlepath")
                        }
                        if store.refreshError {
                            hint("Scores unavailable — showing your saved data.", icon: "wifi.slash")
                        }
                        SportsSectionsView(
                            groups: grouping.groups(for: fixtures),
                            resolved: resolved,
                            emptyChips: emptyChips,
                            isFollowed: isFollowed,
                            onOpenDetail: { selectedFixture = $0 },
                            onWatch: watch,
                            onFollowToggle: toggleFollow,
                            onPickChannel: { pickerFixture = $0 },
                            onSelectLeague: { scope = .league($0) }
                        )
                    }
                    .padding()
                }
            }
            .task(id: resolveKey(fixtures)) { await runResolve(fixtures) }
        }
    }

    private var lockedState: some View {
        ContentUnavailableView {
            Label {
                Text(PremiumFeature.sportsHub.title)
            } icon: {
                Image(systemName: "sportscourt")
            }
        } description: {
            Text(PremiumFeature.sportsHub.subtitle)
        } actions: {
            Button("Unlock Sports Hub") { showPaywall = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func hint(_ text: LocalizedStringKey, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Navigation path

    private var pathBinding: Binding<NavigationPath> {
        if let router {
            return Binding(get: { router.sportsPath }, set: { router.sportsPath = $0 })
        }
        return $localPath
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

    /// Resolves the currently visible fixtures to the viewer's channels in one
    /// off-main pass, re-running when the fixture set changes or an EPG refresh
    /// finishes (fresh sub-titles sharpen matching).
    private func resolveKey(_ fixtures: [SportsFixture]) -> String {
        fixtures.map(\.id).joined(separator: ",") + "|" + String(epg.isSyncing)
    }

    private func runResolve(_ fixtures: [SportsFixture]) async {
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

        let hadSheet = selectedFixture != nil || pickerFixture != nil
        selectedFixture = nil
        pickerFixture = nil
        present(media, afterSheet: hadSheet)
    }

    /// A sheet's dismissal is not done when its binding drops to `nil`, and a
    /// `fullScreenCover` presented while it is still animating out is torn down
    /// and re-presented by UIKit once the sheet has gone — two player instances,
    /// two stream opens, and the second one trips the provider's connection cap
    /// (LumeEngine fails, KSPlayer gets HTTP 429). So when a sheet was open the
    /// media waits here and the sheet's `onDismiss` presents it.
    private func present(_ media: PlayableMedia, afterSheet: Bool) {
        #if os(macOS)
            MacPlayerWindowRouter.shared.play(media, using: openWindow)
        #elseif os(iOS) || os(visionOS)
            if afterSheet {
                pendingMedia = media
            } else {
                playingMedia = media
            }
        #endif
    }

    private func presentPendingMedia() {
        #if os(iOS) || os(visionOS)
            guard let media = pendingMedia else { return }
            pendingMedia = nil
            playingMedia = media
        #endif
    }

    // MARK: - Follow toggle

    private func toggleFollow(_ team: SportsTeam) {
        follows.toggle(team.id, kind: .team)
    }

    private func isFollowed(_ team: SportsTeam) -> Bool {
        follows.isFollowing(team.id)
    }

    // MARK: - Fixture assembly

    /// The shared selection/grouping rules; the phone hub keeps only its chrome.
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

    private var emptyChips: [String] {
        grouping.emptyChips
    }

    private var scopeTitle: String {
        grouping.scopeTitle
    }

    // MARK: - Static helpers

    /// The league id embedded in a team follow key ("espn:soccer/ger.1:132" →
    /// "espn:soccer/ger.1").
    static func leagueId(fromTeamKey key: String) -> String? {
        guard let separator = key.lastIndex(of: ":"), separator > key.startIndex else { return nil }
        return String(key[..<separator])
    }

    /// The half-open date interval a segment covers, relative to `now`.
    static func dateRange(for segment: SportsHubSegment, now: Date, calendar: Calendar = .current) -> Range<Date> {
        let startOfToday = calendar.startOfDay(for: now)
        switch segment {
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return start ..< startOfToday
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
            return startOfToday ..< end
        case .upcoming:
            let end = calendar.date(byAdding: .day, value: 7, to: startOfToday) ?? startOfToday
            return now ..< end
        }
    }
}

#Preview {
    SportsHubView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

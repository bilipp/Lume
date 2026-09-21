//
//  SportsHomeRail.swift
//  Lume
//
//  The Sports row on the Home screen: followed teams' fixtures first, then
//  followed leagues' (today and the next few days), with an onboarding card when
//  nothing is followed and a crown-badged upsell when Lume Pro is locked. The
//  header's "See All" switches to the Sports tab (or opens the hub when the tab
//  is hidden). The whole rail resolves to the viewer's channels with ONE shared
//  off-main pass, never per card. The tvOS branch is a full-width focus-section
//  rail of the same `TVFixtureLogoCard` the hub uses.
//

import SwiftData
import SwiftUI

struct SportsHomeRail: View {
    /// Mirrors `ForYouRow`: the resolve is deferred while a playlist / iCloud /
    /// EPG sync is running, and retries once it settles.
    var isSyncBusy = false

    var body: some View {
        #if os(tvOS)
            TVSportsHomeRail()
        #else
            PhoneSportsHomeRail(isSyncBusy: isSyncBusy)
        #endif
    }
}

#if !os(tvOS)

    /// The Home Sports rail for iOS / iPadOS / macOS / visionOS. Shares the hub's
    /// data plumbing — a `SportsStore` snapshot, `SportsFollowService` follows and
    /// the off-main `SportsChannelResolver` — and resolves the whole rail once via
    /// `.task(id:)`, never per card.
    private struct PhoneSportsHomeRail: View {
        var isSyncBusy: Bool

        @Environment(\.modelContext) private var modelContext
        @Environment(\.contentRestriction) private var restriction
        @Environment(DeepLinkRouter.self) private var router: DeepLinkRouter?
        #if os(macOS)
            @Environment(\.openWindow) private var openWindow
        #endif

        @AppStorage(SportsSyncService.tabEnabledKey) private var sportsTabEnabled = SportsSyncService.tabEnabledDefault

        @State private var premium = PremiumManager.shared
        @State private var store = SportsStore.shared
        @State private var follows = SportsFollowService.shared
        @State private var epg = EPGSyncService.shared

        @State private var resolved: [String: [ResolvedChannel]] = [:]
        @State private var selectedFixture: SportsFixture?
        @State private var pickerFixture: SportsFixture?
        @State private var showManageTeams = false
        @State private var showPaywall = false
        @State private var showHub = false
        #if os(iOS) || os(visionOS)
            @State private var playingMedia: PlayableMedia?
            /// Playback queued behind a dismissing sheet; see `present(_:afterSheet:)`.
            @State private var pendingMedia: PlayableMedia?
        #endif

        private static let cardWidth: CGFloat = 320

        var body: some View {
            let fixtures = railFixtures
            if shouldShow(fixtures) {
                shownContent(fixtures)
                    .sheet(isPresented: $showManageTeams) { ManageTeamsSheet() }
                    .sheet(item: $selectedFixture, onDismiss: presentPendingMedia) { fixture in
                        GameDetailSheet(fixture: fixture, resolved: resolved[fixture.id] ?? [], onWatch: watch)
                    }
                    .sheet(item: $pickerFixture, onDismiss: presentPendingMedia) { fixture in
                        ChannelPickerSheet(fixture: fixture, resolved: resolved[fixture.id] ?? [], onWatch: watch)
                    }
                    .sheet(isPresented: $showHub) { hubSheet }
                    .paywall(isPresented: $showPaywall, highlight: .sportsHub)
                #if os(iOS) || os(visionOS)
                    .fullScreenCover(item: $playingMedia) { media in
                        FullScreenPlayerView(media: media)
                    }
                #endif
                    .task(id: resolveKey(fixtures)) { await runResolve(fixtures) }
                    .onAppear(perform: warm)
                    .onDisappear { SportsSyncService.shared.endLivePolling() }
            }
        }

        /// Premium-gated (the hub is a Lume Pro feature). Free users still see a
        /// crown-badged locked row; premium users see the onboarding card when
        /// nothing is followed, otherwise the rail only when it has fixtures.
        private func shouldShow(_ fixtures: [SportsFixture]) -> Bool {
            guard premium.isPremium else { return true }
            return follows.follows.isEmpty || !fixtures.isEmpty
        }

        @ViewBuilder
        private func shownContent(_ fixtures: [SportsFixture]) -> some View {
            if !premium.isPremium {
                lockedRow
            } else if follows.follows.isEmpty {
                onboardingRow
            } else {
                railRow(fixtures)
            }
        }

        // MARK: - Rows

        private func railRow(_ fixtures: [SportsFixture]) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                header(showSeeAll: true)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(fixtures) { fixture in
                            FixtureCard(
                                fixture: fixture,
                                resolved: resolved[fixture.id] ?? [],
                                isFollowed: isFollowed,
                                onOpenDetail: { selectedFixture = fixture },
                                onWatch: watch,
                                onFollowToggle: toggleFollow,
                                onPickChannel: { pickerFixture = fixture }
                            )
                            .frame(width: Self.cardWidth)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
            }
        }

        private var onboardingRow: some View {
            VStack(alignment: .leading, spacing: 12) {
                header(showSeeAll: false)
                Button {
                    showManageTeams = true
                } label: {
                    promoCard(
                        icon: "sportscourt.fill",
                        title: Text("Follow Your Teams"),
                        message: Text("Add leagues and teams to see fixtures, live scores and standings, with one tap to the channel carrying the game."),
                        accessory: Image(systemName: "chevron.right")
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        }

        private var lockedRow: some View {
            VStack(alignment: .leading, spacing: 12) {
                header(showSeeAll: false)
                Button {
                    showPaywall = true
                } label: {
                    promoCard(
                        icon: "sportscourt.fill",
                        title: Text(PremiumFeature.sportsHub.title),
                        message: Text(PremiumFeature.sportsHub.subtitle),
                        accessory: Image(systemName: "crown.fill")
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        }

        private func header(showSeeAll: Bool) -> some View {
            HStack {
                Text("Sports")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                if showSeeAll {
                    Spacer(minLength: 8)
                    Button(action: seeAll) {
                        HStack(spacing: 2) {
                            Text("See All")
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                                .accessibilityHidden(true)
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
        }

        private func promoCard(icon: String, title: Text, message: Text, accessory: Image) -> some View {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    title
                        .font(.headline)
                        .foregroundStyle(.primary)
                    message
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 8)
                accessory
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }

        // MARK: - Hub fallback

        /// Opened only when the Sports tab is hidden — otherwise "See All" just
        /// switches to that tab. Presented as a sheet (swipe to dismiss) since the
        /// hub brings its own navigation chrome.
        @ViewBuilder
        private var hubSheet: some View {
            SportsHubView()
            #if os(macOS)
                .frame(minWidth: 640, minHeight: 640)
            #endif
        }

        private func seeAll() {
            if sportsTabEnabled, let router {
                router.selectedTab = .sports
            } else {
                showHub = true
            }
        }

        // MARK: - Lifecycle

        /// Loads the cached snapshots, then fetches any followed league that has
        /// none — the system may purge `Caches/` between launches, and the daily
        /// refresh alone would leave the rail empty until it next fell due. Then
        /// catches a stale snapshot up by day and joins the live poll, so the
        /// rail closes out finished games and moves scores like the hub does.
        /// The poll is reference counted and paired with `onDisappear`, so it is
        /// begun outside the premium guard; with nothing followed it is idle.
        private func warm() {
            SportsSyncService.shared.beginLivePolling()
            guard premium.isPremium else { return }
            store.loadCached(leagueIds: displayLeagueIds)
            SportsSyncService.shared.syncIfDue()
            SportsSyncService.shared.refreshMissing()
            SportsSyncService.shared.catchUpIfStale()
        }

        /// Re-runs when the fixture set changes or an EPG/catalog sync finishes
        /// (fresh listings sharpen matching). It never waits for a sync to end: a
        /// long playlist import used to leave every Home card without a channel
        /// while the hub, which never waited, showed them.
        private func resolveKey(_ fixtures: [SportsFixture]) -> String {
            guard premium.isPremium else { return "idle" }
            return fixtures.map(\.id).joined(separator: ",") + "|" + String(epg.isSyncing) + "|" + String(isSyncBusy)
        }

        private func runResolve(_ fixtures: [SportsFixture]) async {
            guard premium.isPremium else { return }
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

        // MARK: - Follow

        private func toggleFollow(_ team: SportsTeam) {
            follows.toggle(team.id, kind: .team)
        }

        private func isFollowed(_ team: SportsTeam) -> Bool {
            follows.isFollowing(team.id)
        }

        // MARK: - Fixture assembly

        private var displayLeagueIds: [String] {
            SportsRailPlanner.displayLeagueIds(for: follows.follows)
        }

        private var railFixtures: [SportsFixture] {
            SportsRailPlanner.fixtures(follows: follows.follows, store: store)
        }
    }

#endif

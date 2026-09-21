//
//  TVSportsHomeRail.swift
//  Lume
//
//  The tvOS Home Sports rail, split from SportsHomeRail.swift to stay under the
//  600-line file cap. Presented by SportsHomeRail's tvOS branch.
//

import SwiftData
import SwiftUI

#if os(tvOS)

    /// The Home Sports rail for tvOS: a full-width `.focusSection()` of compact
    /// crest-only `TVFixtureLogoCard`s for followed teams' fixtures first, then followed leagues'
    /// (today and the next week). Resolves to the viewer's channels in ONE shared
    /// off-main pass, never per card. Hidden when there is nothing to show, save
    /// the onboarding card when nothing is followed and the paywall when locked.
    struct TVSportsHomeRail: View {
        @Environment(\.modelContext) private var modelContext
        @Environment(\.contentRestriction) private var restriction

        @State private var premium = PremiumManager.shared
        @State private var store = SportsStore.shared
        @State private var follows = SportsFollowService.shared
        @State private var epg = EPGSyncService.shared

        @State private var resolved: [String: [ResolvedChannel]] = [:]
        @State private var selectedFixture: SportsFixture?
        @State private var showManageTeams = false
        @State private var showPaywall = false

        @State private var playingMedia: PlayableMedia?
        /// Playback queued behind the dismissing detail cover; see `watch`.
        @State private var pendingMedia: PlayableMedia?

        var body: some View {
            Group {
                if shouldShow { content }
            }
            .sheet(isPresented: $showManageTeams) { TVManageTeamsPane() }
            .fullScreenCover(item: $selectedFixture, onDismiss: presentPendingMedia) { fixture in
                TVGameDetailSheet(fixture: fixture, resolved: resolved[fixture.id] ?? [], onWatch: watch)
            }
            .fullScreenCover(item: $playingMedia) { media in
                FullScreenPlayerView(media: media)
            }
            .paywall(isPresented: $showPaywall, highlight: .sportsHub)
            .onAppear(perform: warm)
            .onDisappear { SportsSyncService.shared.endLivePolling() }
        }

        /// Premium-gated (the hub is a Lume Pro feature). Free users still see a
        /// crown-badged locked row; premium users see the onboarding card when
        /// nothing is followed, otherwise the rail only when it has fixtures.
        private var shouldShow: Bool {
            guard premium.isPremium else { return true }
            return follows.follows.isEmpty || !railFixtures.isEmpty
        }

        @ViewBuilder
        private var content: some View {
            if !premium.isPremium {
                lockedRow
            } else if follows.follows.isEmpty {
                onboardingRow
            } else {
                railRow
            }
        }

        private var railRow: some View {
            VStack(alignment: .leading, spacing: 12) {
                header
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: PosterCardMetrics.railSpacing) {
                        ForEach(railFixtures) { fixture in
                            TVFixtureLogoCard(fixture: fixture) { selectedFixture = fixture }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, PosterCardMetrics.railVerticalPadding)
                }
                .scrollClipDisabled()
            }
            .focusSection()
            .task(id: resolveKey) { await runResolve() }
        }

        private var lockedRow: some View {
            VStack(alignment: .leading, spacing: 12) {
                header
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 20) {
                        Image(systemName: "sportscourt.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(PremiumFeature.sportsHub.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(PremiumFeature.sportsHub.subtitle)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 12)
                        Image(systemName: "crown.fill")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .accessibilityHidden(true)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.08))
                    )
                }
                .buttonStyle(TVCardButtonStyle(focusScale: 1.03))
                .padding(.horizontal)
            }
            .focusSection()
        }

        private var onboardingRow: some View {
            VStack(alignment: .leading, spacing: 12) {
                header
                Button {
                    showManageTeams = true
                } label: {
                    HStack(spacing: 20) {
                        Image(systemName: "sportscourt.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Follow Your Teams")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Add leagues and teams to see fixtures, live scores and standings, with one tap to the channel carrying the game.")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.right")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .accessibilityHidden(true)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.08))
                    )
                }
                .buttonStyle(TVCardButtonStyle(focusScale: 1.03))
                .padding(.horizontal)
            }
            .focusSection()
        }

        /// Same heading style and inset as `HomeRow`, so the Sports row lines up
        /// with every other row on the tvOS Home.
        private var header: some View {
            Text("Sports")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }

        // MARK: - Lifecycle

        /// Loads the cached snapshots, then fetches any followed league that has
        /// none, catches a stale snapshot up and joins the live poll (see
        /// `PhoneSportsHomeRail.warm`).
        private func warm() {
            SportsSyncService.shared.beginLivePolling()
            guard premium.isPremium else { return }
            store.loadCached(leagueIds: displayLeagueIds)
            SportsSyncService.shared.syncIfDue()
            SportsSyncService.shared.refreshMissing()
            SportsSyncService.shared.catchUpIfStale()
        }

        private var resolveKey: String {
            guard premium.isPremium else { return "idle" }
            return railFixtures.map(\.id).joined(separator: ",") + "|" + String(epg.isSyncing)
        }

        private func runResolve() async {
            guard premium.isPremium else { return }
            let fixtures = railFixtures
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

        // MARK: - Follow

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

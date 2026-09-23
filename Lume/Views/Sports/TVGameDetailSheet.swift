//
//  TVGameDetailSheet.swift
//  Lume
//
//  The full tvOS game-detail screen a fixture card opens. It follows the
//  `EPGProgramDetailView.tvBody` conventions — a fixed 10-foot layout sized in
//  explicit points, dismissed with the Menu/Back button (no Close control), with
//  the focusable actions kept above the long non-focusable content so the focus
//  engine can always reach them. It shows a two-colour team gradient header with
//  the score or kickoff, the channels the fixture resolved to in the viewer's own
//  playlists (one confident channel becomes a single prominent Watch button), the
//  Timeline / Stats / Lineup pill tabs fed off-main by the `SportsDataProvider`,
//  and the league standings with the followed team's row highlighted.
//
//  `TVChannelRow` in LiveTVTVComponents is `private` and modelled on a
//  `LiveStream` + `ChannelEPG`, so it cannot carry a `ResolvedChannel`'s quality
//  badge and matched-programme line; this screen uses a purpose-built focusable
//  channel row instead. The Timeline / Stats / Lineup renderers in
//  GameDetailSections are likewise `private` and sized for the phone, so the tabs
//  here render tvOS-scaled variants rather than reaching into that file.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    struct TVGameDetailSheet: View {
        let fixture: SportsFixture
        /// The presenter's resolved channels; when empty the sheet resolves this
        /// one fixture itself (see `GameDetailSheet`).
        let resolved: [ResolvedChannel]
        var onWatch: (ResolvedChannel) -> Void
        var provider: any SportsDataProvider = ESPNClient.shared

        @Environment(\.dismiss) private var dismiss
        @Environment(\.modelContext) private var modelContext
        @Environment(\.contentRestriction) private var restriction
        @State private var follows = SportsFollowService.shared
        @State private var store = SportsStore.shared
        @State private var eventDetail: SportsEventDetail?
        @State private var isLoadingDetail = false
        @State private var fetchedStandings: [SportsStandingRow] = []
        @State private var tab: GameDetailTab = .timeline
        @State private var selfResolved: [ResolvedChannel] = []

        private var channels: [ResolvedChannel] {
            resolved.isEmpty ? selfResolved : resolved
        }

        var body: some View {
            ScrollView {
                VStack(spacing: 48) {
                    header
                    if fixture.status.state != .final {
                        watchSection
                    }
                    detailTabsSection
                    standingsSection
                }
                .frame(maxWidth: 1500)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 90)
                .padding(.vertical, 70)
            }
            .scrollClipDisabled()
            .background(background.ignoresSafeArea())
            .onExitCommand { dismiss() }
            .task(id: fixture.id) { await loadDetail() }
            .onAppear { SportsSyncService.shared.beginLivePolling() }
            .onDisappear { SportsSyncService.shared.endLivePolling() }
        }

        /// The team tints are translucent washes; without a solid base a
        /// fullScreenCover on tvOS lets the hub show through them.
        private var background: some View {
            ZStack {
                Color(white: 0.08)
                TeamPalette.gradient(home: fixture.homePalette, away: fixture.awayPalette)
            }
        }

        // MARK: - Header

        private var header: some View {
            VStack(spacing: 24) {
                leagueLine
                if fixture.hasTeams {
                    matchup
                } else {
                    eventHeader
                }
            }
        }

        private var leagueLine: some View {
            HStack(spacing: 12) {
                if let logo = leagueLogoURL {
                    CachedAsyncImage(url: logo, maxPixelSize: 56) { phase in
                        if case let .success(image) = phase {
                            image.resizable().scaledToFit()
                        } else {
                            Image(systemName: "sportscourt").font(.title3)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                }
                Text(verbatim: fixture.leagueName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }

        private var matchup: some View {
            HStack(alignment: .top, spacing: 48) {
                if let home = fixture.home {
                    teamColumn(home)
                } else {
                    Spacer().frame(maxWidth: .infinity)
                }
                centerStatus.frame(width: 320)
                if let away = fixture.away {
                    teamColumn(away)
                } else {
                    Spacer().frame(maxWidth: .infinity)
                }
            }
        }

        private var eventHeader: some View {
            VStack(spacing: 16) {
                if let kind = fixture.sessionKind {
                    Text(kind.displayName)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                    Text(verbatim: fixture.eventTitle)
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                } else {
                    Text(verbatim: fixture.eventTitle)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if let subtitle = fixture.eventSubtitle {
                        Text(verbatim: subtitle)
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                if fixture.sessions.isEmpty || fixture.status.state != .scheduled {
                    centerStatus
                }
                if !fixture.sessions.isEmpty {
                    sessionList
                }
            }
        }

        /// A race weekend's timetable: every session with its day and time.
        private var sessionList: some View {
            VStack(spacing: 6) {
                ForEach(Array(fixture.sessions.enumerated()), id: \.offset) { _, session in
                    let isCurrent = session.kind == fixture.sessionKind
                    HStack {
                        Text(session.kind.displayName)
                            .font(.system(size: 28, weight: isCurrent ? .bold : .medium))
                            .foregroundStyle(isCurrent ? .white : .white.opacity(0.85))
                        Spacer()
                        Text(session.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(session.date, format: .dateTime.hour().minute())
                            .font(.system(size: 28, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(minWidth: 110, alignment: .trailing)
                    }
                    .tvFocusRow()
                }
            }
            .frame(maxWidth: 900)
            .padding(.top, 8)
        }

        private func teamColumn(_ competitor: SportsCompetitor) -> some View {
            VStack(spacing: 14) {
                TeamCrest(team: competitor.team, size: 130)
                    .accessibilityHidden(true)
                Text(verbatim: competitor.team.name)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let record = competitor.record, !record.isEmpty {
                    Text(verbatim: record)
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let form = competitor.form, !form.isEmpty {
                    Text(verbatim: form)
                        .font(.system(size: 24, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                followButton(competitor.team)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }

        @ViewBuilder
        private var centerStatus: some View {
            switch fixture.status.state {
            case .final:
                VStack(spacing: 10) {
                    scoreText
                    EndedBadge(fontSize: 22)
                    if let qualifier = fixture.status.localizedEndingQualifier(family: fixture.periodFamily) {
                        Text(verbatim: qualifier)
                            .font(.system(size: 26)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            case .inProgress:
                VStack(spacing: 10) {
                    scoreText
                    LiveBadge(fontSize: 22)
                    if let line = fixture.status.localizedLiveDetail(family: fixture.periodFamily) {
                        Text(verbatim: line)
                            .font(.system(size: 26)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            case .scheduled, .postponed:
                Text(fixture.startDate, format: .dateTime.hour().minute())
                    .font(.system(size: 60, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }

        @ViewBuilder
        private var scoreText: some View {
            if fixture.hasTeams {
                Text(verbatim: fixture.scoreLine)
                    .font(.system(size: fixture.hasTextScores ? 48 : 80, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
            }
        }

        private func followButton(_ team: SportsTeam) -> some View {
            let following = follows.isFollowing(team.id)
            return Button {
                follows.toggle(team.id, kind: .team)
            } label: {
                Label(following ? "Following" : "Follow", systemImage: following ? "star.fill" : "star")
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 14)
                    .foregroundStyle(following ? .yellow : .white)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
            .accessibilityLabel(following ? Text("Unfollow \(team.name)") : Text("Follow \(team.name)"))
            .padding(.top, 6)
        }

        // MARK: - Watch

        private var watchSection: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("On Your Channels")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)

                switch channels.count {
                case 0:
                    emptyChannels
                case 1:
                    singleChannel(channels[0])
                default:
                    VStack(spacing: 16) {
                        ForEach(channels) { channelRow($0) }
                    }
                }
            }
            .focusSection()
        }

        private var emptyChannels: some View {
            SportsEmptyChannelsView()
        }

        private func singleChannel(_ channel: ResolvedChannel) -> some View {
            Button {
                onWatch(channel)
            } label: {
                HStack(spacing: 22) {
                    ChannelLogo(urlString: channel.stream.streamIcon, size: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        channelName(channel, size: 30)
                        channelSubtitle(channel)
                    }
                    Spacer(minLength: 16)
                    Label("Watch", systemImage: "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }
            .buttonStyle(TVGlassButtonStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Watch on \(channel.stream.name)"))
        }

        private func channelRow(_ channel: ResolvedChannel) -> some View {
            TVSportsChannelRow(channel: channel, onPlay: { onWatch(channel) })
        }

        private func channelName(_ channel: ResolvedChannel, size: CGFloat) -> some View {
            HStack(spacing: 10) {
                Text(verbatim: channel.stream.name)
                    .font(.system(size: size, weight: .semibold))
                    .lineLimit(1)
                if let badge = sportsQualityBadge(from: channel.stream.name) {
                    Text(verbatim: badge)
                        .font(.system(size: size * 0.6, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }
        }

        @ViewBuilder
        private func channelSubtitle(_ channel: ResolvedChannel) -> some View {
            if let subtitle = channel.matchedSubtitle {
                subtitle
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }

        // MARK: - Tabs

        @ViewBuilder
        private var detailTabsSection: some View {
            if let eventDetail, eventDetail.hasTabContent {
                VStack(spacing: 28) {
                    tabPills(for: eventDetail)
                    tabContent(eventDetail)
                }
            } else if isLoadingDetail {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
        }

        private func tabPills(for detail: SportsEventDetail) -> some View {
            let tabs = detail.availableTabs
            return HStack(spacing: 12) {
                ForEach(tabs) { value in
                    TVTabPill(title: value.title, isActive: tab == value) { tab = value }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.08)))
            .focusSection()
            .onAppear {
                if !tabs.contains(tab), let first = tabs.first { tab = first }
            }
        }

        @ViewBuilder
        private func tabContent(_ detail: SportsEventDetail) -> some View {
            switch tab {
            case .timeline:
                TVTimelineSection(events: detail.keyEvents, fixture: fixture)
            case .stats:
                TVStatsSection(stats: detail.teamStats, homePalette: fixture.homePalette, awayPalette: fixture.awayPalette)
            case .lineup:
                TVLineupSection(lineups: detail.lineups, fixture: fixture)
            }
        }

        // MARK: - Standings

        @ViewBuilder
        private var standingsSection: some View {
            let rows = standingsRows
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Table")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                    let groups = SportsStandingRow.grouped(rows)
                    ForEach(groups) { group in
                        if groups.count > 1, let title = group.title {
                            title
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 12)
                        }
                        // Focus, not touch, scrolls a tvOS ScrollView: a 32-row table
                        // as one focusable block would leave its tail unreachable, so
                        // it is dealt out in screen-sized focusable chunks.
                        VStack(spacing: 4) {
                            ForEach(Array(group.rows.chunked(into: Self.standingsChunk).enumerated()), id: \.offset) { index, chunk in
                                StandingsTable(rows: chunk, followedTeamIds: follows.followedKeys, showsHeader: index == 0)
                                    .tvFocusBlock()
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.06)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private static let standingsChunk = 8

        private var standingsRows: [SportsStandingRow] {
            let cached = store.snapshot(for: fixture.leagueId)?.standings ?? []
            return cached.isEmpty ? fetchedStandings : cached
        }

        // MARK: - Loading

        private func loadDetail() async {
            guard let league = SportsCatalog.league(id: fixture.leagueId) else { return }
            let expectsDetail = fixture.status.state == .inProgress || fixture.status.state == .final
            if expectsDetail { isLoadingDetail = true }
            defer { isLoadingDetail = false }

            if resolved.isEmpty, fixture.status.state != .final {
                selfResolved = await SportsChannelResolver.resolve(
                    container: modelContext.container,
                    fixtures: [fixture],
                    now: Date(),
                    restriction: restriction
                )[fixture.id] ?? []
            }
            if store.snapshot(for: fixture.leagueId)?.standings.isEmpty ?? true, fetchedStandings.isEmpty {
                fetchedStandings = await (try? provider.standings(league: league)) ?? []
            }
            eventDetail = try? await provider.eventDetail(league: league, eventId: fixture.eventId)
        }

        // MARK: - Derived

        private var leagueLogoURL: URL? {
            fixture.leagueLogoURL ?? SportsCatalog.league(id: fixture.leagueId)?.logoURL
        }
    }
#endif

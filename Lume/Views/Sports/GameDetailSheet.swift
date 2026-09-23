//
//  GameDetailSheet.swift
//  Lume
//
//  The game-detail sheet a fixture card opens. This part builds the header —
//  the two-colour team gradient behind the league line, the crests, the big
//  score or kickoff time, each team's record and form, and a per-team Following
//  toggle — and the Watch card that surfaces the channels resolved in the
//  viewer's own playlists, plus the Timeline / Stats / Lineup tabs and the
//  embedded standings table — the tabs are fed by a `SportsEventDetail` loaded
//  off-main from the `SportsDataProvider`, and hide themselves for a pre-match
//  fixture that has nothing to show.
//

import SwiftData
import SwiftUI

struct GameDetailSheet: View {
    let fixture: SportsFixture
    /// The presenter's resolved channels. When it hands over none — its own
    /// resolve pass still running, or never run — the sheet resolves this one
    /// fixture itself.
    let resolved: [ResolvedChannel]
    var onWatch: (ResolvedChannel) -> Void
    var provider: any SportsDataProvider = ESPNClient.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @Environment(DeepLinkRouter.self) private var router: DeepLinkRouter?
    @State private var follows = SportsFollowService.shared
    @State private var store = SportsStore.shared
    @State private var eventDetail: SportsEventDetail?
    @State private var isLoadingDetail = false
    @State private var fetchedStandings: [SportsStandingRow] = []
    @State private var selfResolved: [ResolvedChannel] = []

    private var channels: [ResolvedChannel] {
        resolved.isEmpty ? selfResolved : resolved
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if fixture.status.state != .final {
                        watchCard
                    }
                    detailTabs
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .background(background.ignoresSafeArea())
            .platformNavigationTitle("Game")
            .hubInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .gameDetailPlatformChrome()
        .task(id: fixture.id) { await loadDetail() }
        .onAppear { SportsSyncService.shared.beginLivePolling() }
        .onDisappear { SportsSyncService.shared.endLivePolling() }
    }

    // MARK: - Background

    private var background: some View {
        TeamPalette.gradient(home: fixture.homePalette, away: fixture.awayPalette)
            .overlay(Color.black.opacity(0.35))
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 18) {
            leagueLine
            if fixture.hasTeams {
                matchup
            } else {
                eventHeader
            }
        }
    }

    private var leagueLine: some View {
        HStack(spacing: 8) {
            if let logo = leagueLogoURL {
                CachedAsyncImage(url: logo, maxPixelSize: 40) { phase in
                    switch phase {
                    case let .success(image): image.resizable().scaledToFit()
                    default: Image(systemName: "sportscourt").font(.caption)
                    }
                }
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            }
            Text(verbatim: fixture.leagueName)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private var matchup: some View {
        HStack(alignment: .top, spacing: 12) {
            if let home = fixture.home {
                teamColumn(home)
            } else {
                Spacer().frame(maxWidth: .infinity)
            }
            centerStatus
                .frame(minWidth: 96)
            if let away = fixture.away {
                teamColumn(away)
            } else {
                Spacer().frame(maxWidth: .infinity)
            }
        }
    }

    /// A session card is titled by its session, with the Grand Prix beneath; a
    /// whole weekend or a fight night is titled by its name, with the venue.
    private var eventHeader: some View {
        VStack(spacing: 12) {
            if let kind = fixture.sessionKind {
                Text(kind.displayName)
                    .font(.title3.weight(.bold))
                Text(verbatim: fixture.eventTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text(verbatim: fixture.eventTitle)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                if let subtitle = fixture.eventSubtitle {
                    Text(verbatim: subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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

    /// A race weekend's timetable — every session with its day and time, in
    /// place of the single first-practice start the fixture date would show.
    private var sessionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(fixture.sessions.enumerated()), id: \.offset) { index, session in
                let isCurrent = session.kind == fixture.sessionKind
                if index > 0 { Divider().opacity(0.35) }
                HStack {
                    Text(session.kind.displayName)
                        .font(.subheadline.weight(isCurrent ? .bold : .medium))
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    Spacer()
                    Text(session.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(session.date, format: .dateTime.hour().minute())
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 52, alignment: .trailing)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 4)
    }

    private func teamColumn(_ competitor: SportsCompetitor) -> some View {
        VStack(spacing: 8) {
            TeamCrest(team: competitor.team, size: 64)
            Text(verbatim: competitor.team.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let record = competitor.record, !record.isEmpty {
                Text(verbatim: record)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let form = competitor.form, !form.isEmpty {
                Text(verbatim: form)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            followButton(competitor.team)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var centerStatus: some View {
        switch fixture.status.state {
        case .final:
            VStack(spacing: 6) {
                scoreText
                EndedBadge(fontSize: 12)
                if let qualifier = fixture.status.localizedEndingQualifier(family: fixture.periodFamily) {
                    Text(verbatim: qualifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .inProgress:
            VStack(spacing: 6) {
                scoreText
                LiveBadge(fontSize: 12)
                if let line = fixture.status.localizedLiveDetail(family: fixture.periodFamily) {
                    Text(verbatim: line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .scheduled, .postponed:
            Text(fixture.startDate, format: .dateTime.hour().minute())
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    /// The two-sided score; a race or fight night has none, so its header keeps
    /// just the status line. It claims its width before the team columns do —
    /// an HStack otherwise hands it a third of the row and a high-scoring game
    /// truncates to "19…" — and shrinks rather than clips if even that is tight.
    @ViewBuilder
    private var scoreText: some View {
        if fixture.hasTeams {
            Text(verbatim: fixture.scoreLine)
                .font(.system(size: fixture.hasTextScores ? 26 : 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(1)
        }
    }

    @ViewBuilder
    private func followButton(_ team: SportsTeam) -> some View {
        let following = follows.isFollowing(team.id)
        Button {
            follows.toggle(team.id, kind: .team)
        } label: {
            Label(following ? "Following" : "Follow", systemImage: following ? "star.fill" : "star")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(following ? .yellow : .secondary)
        .accessibilityLabel(following ? Text("Unfollow \(team.name)") : Text("Follow \(team.name)"))
    }

    // MARK: - Watch card

    private var watchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On Your Channels")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            switch channels.count {
            case 0:
                emptyChannels
            case 1:
                singleChannel(channels[0])
            default:
                ForEach(channels) { channelRow($0) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private var emptyChannels: some View {
        SportsEmptyChannelsView()
    }

    private func singleChannel(_ channel: ResolvedChannel) -> some View {
        Button {
            onWatch(channel)
        } label: {
            HStack(spacing: 12) {
                ChannelLogo(urlString: channel.stream.streamIcon, size: 36)
                SportsChannelLabel(channel: channel)
                Spacer(minLength: 8)
                Label("Watch", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityLabel(Text("Watch on \(channel.stream.name)"))
    }

    private func channelRow(_ channel: ResolvedChannel) -> some View {
        Button {
            onWatch(channel)
        } label: {
            SportsChannelRow(channel: channel)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Watch on \(channel.stream.name)"))
    }

    // MARK: - Detail tabs

    @ViewBuilder
    private var detailTabs: some View {
        detailTabsSection
        standingsCard
    }

    @ViewBuilder
    private var detailTabsSection: some View {
        if let eventDetail, eventDetail.hasTabContent {
            GameDetailTabs(
                detail: eventDetail,
                fixture: fixture,
                homePalette: fixture.homePalette,
                awayPalette: fixture.awayPalette
            )
        } else if isLoadingDetail {
            GameDetailTabsSkeleton()
        }
    }

    @ViewBuilder
    private var standingsCard: some View {
        let rows = standingsRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Table")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GroupedStandingsTable(rows: rows, followedTeamIds: follows.followedKeys, onSelectLeague: selectLeague)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var standingsRows: [SportsStandingRow] {
        let cached = store.snapshot(for: fixture.leagueId)?.standings ?? []
        return cached.isEmpty ? fetchedStandings : cached
    }

    // MARK: - Loading

    /// Fetches the event's timeline/stats/lineups off-main, plus the league table
    /// when it is not already cached in the store. A skeleton shows only for a
    /// live or finished fixture, where detail is expected.
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

    private func selectLeague() {
        guard let league = SportsCatalog.league(id: fixture.leagueId) else { return }
        dismiss()
        router?.sportsPath.append(league)
    }

    // MARK: - Derived

    private var leagueLogoURL: URL? {
        fixture.leagueLogoURL ?? SportsCatalog.league(id: fixture.leagueId)?.logoURL
    }
}

private extension View {
    /// Per-platform sheet chrome kept in one `#if` so SwiftFormat cannot
    /// reindent adjacent conditionals in the modifier chain.
    @ViewBuilder
    func gameDetailPlatformChrome() -> some View {
        #if os(macOS)
            frame(minWidth: 460, minHeight: 560)
        #elseif os(iOS)
            presentationDetents([.large])
        #else
            self
        #endif
    }
}

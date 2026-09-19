//
//  LeagueDetailView.swift
//  Lume
//
//  The full-screen league detail, pushed onto `DeepLinkRouter.sportsPath` from a
//  standings table's league tap or the game-detail sheet. The whole screen is
//  washed with the league's colour — falling back to the leading team's colour,
//  since a league itself carries none — over which a Yesterday | Today | Upcoming
//  segmented control walks that league's fixtures (reusing `FixtureCard`) and an
//  embedded `StandingsTable` shows the table. For Formula 1 the fixtures become a
//  race-weekend session list and the table splits into driver and constructor
//  standings.
//
//  Channel resolution, playback routing and the game-detail / channel-picker
//  sheets mirror `SportsHubView`: one off-main resolve per visible fixture set,
//  playback through the existing `PlayableMedia` lookup, sheets dismissed before
//  a player is presented.
//

import SwiftData
import SwiftUI

struct LeagueDetailView: View {
    let league: SportsLeague
    var provider: any SportsDataProvider = ESPNClient.shared

    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    @State private var store = SportsStore.shared
    @State private var follows = SportsFollowService.shared
    @State private var epg = EPGSyncService.shared

    @State private var segment: SportsHubSegment = .today
    @State private var resolved: [String: [ResolvedChannel]] = [:]
    @State private var fetchedFixtures: [SportsFixture] = []
    @State private var fetchedStandings: [SportsStandingRow] = []
    @State private var isLoading = false
    @State private var selectedFixture: SportsFixture?
    @State private var pickerFixture: SportsFixture?
    /// Unused on macOS (playback opens a window), but declared on every platform
    /// so the shared `leagueDetailPlayer(media:)` chrome has a binding to take.
    @State private var playingMedia: PlayableMedia?

    private var isF1: Bool {
        league.sport == "racing"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                rangePicker
                fixturesSection
                standingsSection
            }
            .padding()
        }
        .background(background.ignoresSafeArea())
        .navigationTitle(Text(verbatim: league.name))
        .task { await load() }
        .task(id: resolveKey) { await runResolve() }
        .onAppear { SportsSyncService.shared.beginLivePolling() }
        .onDisappear { SportsSyncService.shared.endLivePolling() }
        .sheet(item: $selectedFixture) { fixture in
            GameDetailSheet(fixture: fixture, resolved: resolved[fixture.id] ?? [], onWatch: watch)
        }
        .sheet(item: $pickerFixture) { fixture in
            ChannelPickerSheet(fixture: fixture, resolved: resolved[fixture.id] ?? [], onWatch: watch)
        }
        .leagueDetailPlayer(media: $playingMedia)
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        Picker("Range", selection: $segment) {
            ForEach(SportsHubSegment.allCases) { segment in
                Text(segment.title).tag(segment)
            }
        }
        .hubSegmentedPickerStyle()
    }

    // MARK: - Fixtures

    @ViewBuilder
    private var fixturesSection: some View {
        let fixtures = visibleFixtures
        if isLoading, fixtures.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if fixtures.isEmpty {
            SportsNoGamesView(chips: [])
        } else if isF1 {
            ForEach(fixtures) { weekendCard($0) }
        } else if segment == .upcoming {
            ForEach(SportsFixtureGroup.byDay(fixtures)) { group in
                dayGroup(group)
            }
        } else {
            ForEach(fixtures) { fixtureCard($0) }
        }
    }

    private func fixtureCard(_ fixture: SportsFixture) -> some View {
        FixtureCard(
            fixture: fixture,
            resolved: resolved[fixture.id] ?? [],
            isFollowed: { follows.isFollowing($0.id) },
            onOpenDetail: { selectedFixture = fixture },
            onWatch: watch,
            onFollowToggle: toggleFollow,
            onPickChannel: { pickerFixture = fixture }
        )
    }

    private func dayGroup(_ group: SportsFixtureGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: group.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Divider().offset(y: 6) }
                .padding(.bottom, 6)
            ForEach(group.fixtures) { fixtureCard($0) }
        }
    }

    /// A Formula 1 race weekend: the round's venue and each session's time.
    private func weekendCard(_ fixture: SportsFixture) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: fixture.venue ?? fixture.leagueName)
                .font(.headline)
            if fixture.sessions.isEmpty {
                sessionRow(name: fixture.leagueAbbreviation, date: fixture.startDate)
            } else {
                ForEach(Array(fixture.sessions.enumerated()), id: \.offset) { _, session in
                    sessionRow(name: session.kind.rawValue, date: session.date)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func sessionRow(name: String, date: Date) -> some View {
        HStack {
            Text(verbatim: name)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(date, format: .dateTime.weekday(.abbreviated).hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Standings

    @ViewBuilder
    private var standingsSection: some View {
        if isF1 {
            f1Standings
        } else {
            let rows = teamStandings
            if !rows.isEmpty {
                card("Standings") {
                    StandingsTable(rows: rows, followedTeamIds: follows.followedKeys)
                }
            }
        }
    }

    @ViewBuilder
    private var f1Standings: some View {
        let rows = teamStandings
        let drivers = rows.filter { $0.kind == .driver }
        let constructors = rows.filter { $0.kind == .constructor }
        if !drivers.isEmpty {
            card("Drivers") {
                F1StandingsList(rows: drivers, followedTeamIds: follows.followedKeys)
            }
        }
        if !constructors.isEmpty {
            card("Constructors") {
                F1StandingsList(rows: constructors, followedTeamIds: follows.followedKeys)
            }
        }
    }

    private func card(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity)
        .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Derived data

    private var snapshotFixtures: [SportsFixture] {
        let cached = store.snapshot(for: league.id)?.fixtures ?? []
        return cached.isEmpty ? fetchedFixtures : cached
    }

    private var teamStandings: [SportsStandingRow] {
        let cached = store.snapshot(for: league.id)?.standings ?? []
        return cached.isEmpty ? fetchedStandings : cached
    }

    private var visibleFixtures: [SportsFixture] {
        let range = SportsHubView.dateRange(for: segment, now: Date())
        return snapshotFixtures
            .filter { range.contains($0.startDate) }
            .sorted(by: SportsFixture.displayOrder)
    }

    // MARK: - Background wash

    private var background: some View {
        LinearGradient(
            colors: [tintColor.opacity(0.28), tintColor.opacity(0.05), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var tintColor: Color {
        if let hex = leaderTeamColorHex, let usable = TeamPalette.usableTint(fromHex: hex) {
            return usable
        }
        return TeamPalette.neutral.primary
    }

    private var leaderTeamColorHex: String? {
        let rows = teamStandings
        guard let leader = rows.first(where: { $0.kind == .team }) ?? rows.first else { return nil }
        let teamId = leader.teamId ?? leader.id
        return store.team(by: teamId)?.colorHex
    }

    // MARK: - Loading

    private func load() async {
        let snapshot = store.snapshot(for: league.id)
        let needsFixtures = (snapshot?.fixtures.isEmpty ?? true) && fetchedFixtures.isEmpty
        let needsStandings = (snapshot?.standings.isEmpty ?? true) && fetchedStandings.isEmpty
        guard needsFixtures || needsStandings else { return }

        if needsFixtures { isLoading = true }
        defer { isLoading = false }

        if needsFixtures {
            var byID: [String: SportsFixture] = [:]
            for month in monthsToFetch() {
                let fetched = await (try? provider.fixtures(league: league, month: month)) ?? []
                for fixture in fetched {
                    byID[fixture.id] = fixture
                }
            }
            fetchedFixtures = byID.values.sorted(by: SportsFixture.displayOrder)
        }
        if needsStandings {
            fetchedStandings = await (try? provider.standings(league: league)) ?? []
        }
    }

    /// Previous, current and next month, so both the Yesterday window near a
    /// month start and the seven-day Upcoming window near a month end are covered.
    private func monthsToFetch(now: Date = Date(), calendar: Calendar = .current) -> [DateComponents] {
        var months: [DateComponents] = []
        for offset in -1 ... 1 {
            if let date = calendar.date(byAdding: .month, value: offset, to: now) {
                months.append(calendar.dateComponents([.year, .month], from: date))
            }
        }
        return months
    }

    // MARK: - Resolve

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

    // MARK: - Actions

    private func toggleFollow(_ team: SportsTeam) {
        follows.toggle(team.id, kind: .team)
    }

    private func watch(_ channel: ResolvedChannel) {
        guard let media = SportsPlayback.media(for: channel, in: modelContext) else { return }

        let hadSheet = selectedFixture != nil || pickerFixture != nil
        selectedFixture = nil
        pickerFixture = nil
        present(media, afterSheet: hadSheet)
    }

    private func present(_ media: PlayableMedia, afterSheet: Bool) {
        #if os(macOS)
            MacPlayerWindowRouter.shared.play(media, using: openWindow)
        #elseif os(iOS) || os(visionOS)
            if afterSheet {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    playingMedia = media
                }
            } else {
                playingMedia = media
            }
        #endif
    }
}

// MARK: - F1 standings

/// A compact rank / name / points table for Formula 1 driver and constructor
/// standings, where the GP W D L GD columns of `StandingsTable` do not apply.
private struct F1StandingsList: View {
    let rows: [SportsStandingRow]
    let followedTeamIds: Set<String>

    var body: some View {
        Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                headerCell("RK").gridColumnAlignment(.trailing)
                headerCell("", alignment: .leading).gridColumnAlignment(.leading)
                headerCell("PTS").gridColumnAlignment(.trailing)
            }
            .accessibilityHidden(true)
            Divider()
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().opacity(0.35)
                }
                dataRow(row)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .contain)
    }

    private func headerCell(_ title: String, alignment: Alignment = .trailing) -> some View {
        Text(verbatim: title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: alignment == .leading ? .infinity : nil, alignment: alignment)
    }

    @ViewBuilder
    private func dataRow(_ row: SportsStandingRow) -> some View {
        let followed = followedTeamIds.containsFollowedTeam(for: row)
        GridRow {
            Text(verbatim: "\(row.rank)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .background(standingsRowHighlight(followed))
                .accessibilityHidden(true)
            HStack(spacing: 5) {
                if followed {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                Text(verbatim: row.name)
                    .fontWeight(followed ? .semibold : .regular)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(standingsRowHighlight(followed))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowLabel(row, followed: followed))
            Text(verbatim: row.points.map { "\($0)" } ?? "–")
                .monospacedDigit()
                .fontWeight(.semibold)
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .background(standingsRowHighlight(followed))
                .accessibilityHidden(true)
        }
    }

    private func rowLabel(_ row: SportsStandingRow, followed: Bool) -> Text {
        var value = String(localized: "\(row.name), rank \(row.rank)")
        if let points = row.points {
            value += ", " + String(localized: "\(points) points")
        }
        if followed {
            value = String(localized: "Following") + ", " + value
        }
        return Text(verbatim: value)
    }
}

private extension View {
    /// The full-screen player cover, iOS/visionOS only, kept in one `#if` so
    /// SwiftFormat cannot reindent an adjacent conditional in the modifier chain.
    @ViewBuilder
    func leagueDetailPlayer(media: Binding<PlayableMedia?>) -> some View {
        #if os(iOS) || os(visionOS)
            fullScreenCover(item: media) { media in
                FullScreenPlayerView(media: media)
            }
        #else
            self
        #endif
    }
}

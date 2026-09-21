//
//  GameDetailSections.swift
//  Lume
//
//  The Timeline / Stats / Lineup tabs that drop into the game-detail sheet below
//  its header and Watch card. They render a `SportsEventDetail` the sheet loads
//  off-main from the `SportsDataProvider`: a match timeline of key events, a
//  per-team stats comparison drawn with each side's `TeamPalette`, and the two
//  starting lineups. The pill-segmented control only offers the tabs that carry
//  content, so a fixture with, say, no lineups never shows an empty Lineup tab.
//  Team colours and crests resolve off the fixture's two competitors by their raw
//  provider team id — provider names (players, stats) are shown verbatim.
//

import SwiftUI

nonisolated extension SportsEventDetail {
    /// Whether there is anything to show in the tabs; the sheet hides the whole
    /// block (and never flashes a skeleton) for a pre-match fixture with none.
    var hasTabContent: Bool {
        !keyEvents.isEmpty || !teamStats.isEmpty || !lineups.isEmpty
    }
}

extension SportsEventDetail {
    /// The tabs that carry content, in fixed Timeline / Stats / Lineup order.
    /// Drives both game-detail sheets so their pill selectors stay in step.
    var availableTabs: [GameDetailTab] {
        var tabs: [GameDetailTab] = []
        if !keyEvents.isEmpty { tabs.append(.timeline) }
        if !teamStats.isEmpty { tabs.append(.stats) }
        if !lineups.isEmpty { tabs.append(.lineup) }
        return tabs
    }
}

enum GameDetailTab: String, CaseIterable, Identifiable {
    case timeline
    case stats
    case lineup

    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
        case .timeline: "Timeline"
        case .stats: "Stats"
        case .lineup: "Lineup"
        }
    }
}

/// The pill-segmented tab block below the header. Owns its selected tab and keeps
/// it pinned to a tab that actually has content.
struct GameDetailTabs: View {
    let detail: SportsEventDetail
    let fixture: SportsFixture
    let homePalette: TeamPalette
    let awayPalette: TeamPalette

    @State private var tab: GameDetailTab = .timeline

    var body: some View {
        let tabs = detail.availableTabs
        VStack(spacing: 16) {
            Picker(selection: $tab) {
                ForEach(tabs) { Text($0.title).tag($0) }
            } label: {
                EmptyView()
            }
            .hubSegmentedPickerStyle()
            .labelsHidden()

            selectedSection
        }
        .padding()
        .frame(maxWidth: .infinity)
        .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
        .onAppear {
            if !tabs.contains(tab), let first = tabs.first { tab = first }
        }
    }

    @ViewBuilder
    private var selectedSection: some View {
        switch tab {
        case .timeline:
            TimelineSection(events: detail.keyEvents, fixture: fixture)
        case .stats:
            StatsSection(stats: detail.teamStats, homePalette: homePalette, awayPalette: awayPalette)
        case .lineup:
            LineupSection(lineups: detail.lineups, fixture: fixture)
        }
    }
}

/// A redacted stand-in shown while the event detail loads for a live or finished
/// fixture (never for a pre-match one, which has nothing to load).
struct GameDetailTabsSkeleton: View {
    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 32)
            ForEach(0 ..< 4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(height: 18)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
        .redacted(reason: .placeholder)
    }
}

/// A key-event crest: the matched team's logo, or a small dot in that side's
/// tint when the provider gave no resolvable team. Shared by both game-detail
/// timelines, which differ only in size.
struct SportsTimelineCrest: View {
    let fixture: SportsFixture
    let teamId: String?
    let crestSize: CGFloat
    let dotSize: CGFloat

    var body: some View {
        if let team = fixture.team(forTeamId: teamId) {
            TeamCrest(team: team, size: crestSize)
        } else {
            Circle().fill(fixture.palette(forTeamId: teamId).primary).frame(width: dotSize, height: dotSize)
        }
    }
}

// MARK: - Timeline

private struct TimelineSection: View {
    let events: [SportsKeyEvent]
    let fixture: SportsFixture

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                row(event)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ event: SportsKeyEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: event.clock)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .leading)
            icon(event).frame(width: 18)
            crest(for: event.teamId)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: event.localizedTitle)
                    .font(.subheadline.weight(.medium))
                if !event.participants.isEmpty {
                    Text(verbatim: event.participants.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func icon(_ event: SportsKeyEvent) -> some View {
        if event.isGoal {
            Image(systemName: "soccerball")
        } else if event.isCard {
            RoundedRectangle(cornerRadius: 2).fill(cardColor(event)).frame(width: 11, height: 15)
        } else if event.isSubstitution {
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.green)
        } else {
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary)
        }
    }

    /// The card colour; a card the model could not classify as yellow shows red.
    private func cardColor(_ event: SportsKeyEvent) -> Color {
        event.isYellowCard ? .yellow : .red
    }

    private func crest(for teamId: String?) -> some View {
        SportsTimelineCrest(fixture: fixture, teamId: teamId, crestSize: 20, dotSize: 12)
    }
}

// MARK: - Stats

private struct StatsSection: View {
    let stats: [SportsTeamStat]
    let homePalette: TeamPalette
    let awayPalette: TeamPalette

    var body: some View {
        VStack(spacing: 14) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                statRow(stat)
            }
        }
    }

    private func statRow(_ stat: SportsTeamStat) -> some View {
        VStack(spacing: 6) {
            Text(verbatim: stat.localizedName)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(verbatim: stat.homeDisplay)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                bar(stat)
                Text(verbatim: stat.awayDisplay)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: stat.localizedName))
        .accessibilityValue(Text(String(localized: "\(stat.homeDisplay) versus \(stat.awayDisplay)")))
    }

    @ViewBuilder
    private func bar(_ stat: SportsTeamStat) -> some View {
        let home = max(0, stat.homeValue ?? 0)
        let away = max(0, stat.awayValue ?? 0)
        let total = home + away
        GeometryReader { geo in
            let usable = max(0, geo.size.width - 2)
            if total > 0 {
                HStack(spacing: 2) {
                    Capsule()
                        .fill(homePalette.primary)
                        .frame(width: max(2, CGFloat(home / total) * usable))
                    Capsule()
                        .fill(awayPalette.primary)
                        .frame(width: max(2, CGFloat(away / total) * usable))
                }
            } else {
                Capsule().fill(.quaternary)
            }
        }
        .frame(height: 6)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Lineup

private struct LineupSection: View {
    let lineups: [SportsLineup]
    let fixture: SportsFixture

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(lineups.enumerated()), id: \.offset) { _, lineup in
                teamLineup(lineup)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func teamLineup(_ lineup: SportsLineup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let team = team(for: lineup.teamId) {
                    TeamCrest(team: team, size: 22)
                    Text(verbatim: team.name).font(.headline)
                }
                Spacer(minLength: 0)
                if let formation = lineup.formation, !formation.isEmpty {
                    Text(verbatim: formation)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(lineup.starters.enumerated()), id: \.offset) { _, player in
                playerRow(player)
            }
        }
    }

    private func playerRow(_ player: SportsLineupPlayer) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: player.jersey ?? "")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
            Text(verbatim: player.name)
                .font(.subheadline)
            Spacer(minLength: 0)
            if let position = player.position, !position.isEmpty {
                Text(verbatim: position)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func team(for teamId: String) -> SportsTeam? {
        fixture.team(forTeamId: teamId)
    }
}

//
//  StandingsTable.swift
//  Lume
//
//  The reusable standings grid the Sports Hub draws in a game-detail sheet and,
//  later, in the full league-detail screen. It renders one league's table —
//  rank, team, and the GP W D L GD PTS columns — as a `Grid` so the columns
//  align across rows and every cell scales with Dynamic Type (no fixed heights).
//  A followed team's row is starred and washed with a subtle highlight band.
//  A championship table of drivers or constructors (F1, IndyCar, NASCAR) has
//  no games-played figures, so it collapses to rank, name and points.
//
//  It stays deliberately dumb: it takes a flat `[SportsStandingRow]` plus the
//  set of followed team ids and an optional tap callback. The caller decides
//  what a tap does — the hub wires it to append a league to
//  `DeepLinkRouter.sportsPath` so the full table pushes on.
//

import SwiftUI

struct StandingsTable: View {
    let rows: [SportsStandingRow]
    /// Full follow keys (`SportsTeam.id`, i.e. "espn:{sport}/{slug}:{teamId}").
    /// Matched against each row's raw provider id via a colon-anchored suffix so
    /// the raw `teamId` on a standing row lines up with a full follow key.
    let followedTeamIds: Set<String>
    /// Non-nil turns the whole table into a tap target; the caller appends the
    /// league to `DeepLinkRouter.sportsPath`. `nil` on the league screen itself,
    /// where there is nowhere further to go.
    var onSelectLeague: (() -> Void)?
    /// tvOS renders a long table as several focusable chunks; only the first
    /// carries the column header.
    var showsHeader = true

    init(
        rows: [SportsStandingRow],
        followedTeamIds: Set<String>,
        onSelectLeague: (() -> Void)? = nil,
        showsHeader: Bool = true
    ) {
        self.rows = rows
        self.followedTeamIds = followedTeamIds
        self.onSelectLeague = onSelectLeague
        self.showsHeader = showsHeader
    }

    /// Whether every row is a driver or constructor: the season-long points
    /// tables of motorsport, which have no per-game columns.
    private var isChampionshipTable: Bool {
        !rows.isEmpty && rows.allSatisfy { $0.kind != .team }
    }

    var body: some View {
        Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 0) {
            if showsHeader {
                headerRow
                Divider()
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().opacity(0.35)
                }
                dataRow(row)
            }
        }
        .font(.subheadline)
        .contentShape(Rectangle())
        .modifier(TapToSelect(action: onSelectLeague))
        .accessibilityElement(children: .contain)
    }

    // MARK: - Rows

    private var headerRow: some View {
        GridRow {
            headerCell("RK").gridColumnAlignment(.trailing)
            headerCell(isChampionshipTable ? "" : "Team", alignment: .leading).gridColumnAlignment(.leading)
            if !isChampionshipTable {
                headerCell("GP").gridColumnAlignment(.trailing)
                headerCell("W").gridColumnAlignment(.trailing)
                headerCell("D").gridColumnAlignment(.trailing)
                headerCell("L").gridColumnAlignment(.trailing)
                headerCell("GD").gridColumnAlignment(.trailing)
            }
            headerCell("PTS").gridColumnAlignment(.trailing)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func dataRow(_ row: SportsStandingRow) -> some View {
        let followed = followedTeamIds.containsFollowedTeam(for: row)
        GridRow {
            numberCell(row.rank, followed: followed)
            teamCell(row, followed: followed)
            if !isChampionshipTable {
                statCell(row.played, followed: followed, accessibility: statLabel(row.played) { Text("Games played \($0)") })
                statCell(row.wins, followed: followed, accessibility: statLabel(row.wins) { Text("Wins \($0)") })
                statCell(row.draws, followed: followed, accessibility: statLabel(row.draws) { Text("Draws \($0)") })
                statCell(row.losses, followed: followed, accessibility: statLabel(row.losses) { Text("Losses \($0)") })
                statCell(row.goalDifference, followed: followed, accessibility: statLabel(row.goalDifference) { Text("Goal difference \($0)") })
            }
            pointsCell(row.points, followed: followed)
        }
    }

    /// A stat cell's spoken label, or the raw dash for a missing value.
    private func statLabel(_ value: Int?, _ make: (Int) -> Text) -> Text {
        value.map(make) ?? Text(verbatim: "–")
    }

    /// The whole row folded into the team cell so VoiceOver speaks one element:
    /// "[Following, ] name, rank N, P points".
    private func teamRowLabel(_ row: SportsStandingRow, followed: Bool) -> Text {
        var value = String(localized: "\(row.name), rank \(row.rank)")
        if let points = row.points {
            value += ", " + String(localized: "\(points) points")
        }
        if followed {
            value = String(localized: "Following") + ", " + value
        }
        return Text(verbatim: value)
    }

    // MARK: - Cells

    private func headerCell(_ title: LocalizedStringKey, alignment: Alignment = .trailing) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, cellPadding)
            .frame(maxWidth: alignment == .leading ? .infinity : nil, alignment: alignment)
    }

    private func teamCell(_ row: SportsStandingRow, followed: Bool) -> some View {
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
        .padding(.horizontal, cellPadding)
        .background(standingsRowHighlight(followed))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(teamRowLabel(row, followed: followed))
    }

    private func numberCell(_ value: Int, followed: Bool) -> some View {
        Text(verbatim: "\(value)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .padding(.horizontal, cellPadding)
            .background(standingsRowHighlight(followed))
            .accessibilityHidden(true)
    }

    private func statCell(_ value: Int?, followed: Bool, accessibility: Text) -> some View {
        Text(verbatim: value.map { "\($0)" } ?? "–")
            .monospacedDigit()
            .padding(.vertical, 8)
            .padding(.horizontal, cellPadding)
            .background(standingsRowHighlight(followed))
            .accessibilityLabel(accessibility)
    }

    private func pointsCell(_ value: Int?, followed: Bool) -> some View {
        Text(verbatim: value.map { "\($0)" } ?? "–")
            .monospacedDigit()
            .fontWeight(.semibold)
            .padding(.vertical, 8)
            .padding(.horizontal, cellPadding)
            .background(standingsRowHighlight(followed))
            .accessibilityHidden(true)
    }

    // MARK: - Styling

    private var cellPadding: CGFloat {
        8
    }
}

/// A league's standings as one table per group — a conference, a division,
/// F1's drivers and constructors — each under its own caption when there is
/// more than one, so ranks never appear to restart mid-list.
struct GroupedStandingsTable: View {
    let rows: [SportsStandingRow]
    let followedTeamIds: Set<String>
    var onSelectLeague: (() -> Void)?

    var body: some View {
        let groups = SportsStandingRow.grouped(rows)
        VStack(alignment: .leading, spacing: 16) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if groups.count > 1, let title = group.title {
                        title
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    }
                    StandingsTable(rows: group.rows, followedTeamIds: followedTeamIds, onSelectLeague: onSelectLeague)
                }
            }
        }
    }
}

extension SportsStandingGroup {
    /// The caption over one table: "Drivers" / "Constructors" for motorsport,
    /// else the provider's own group name ("American Football Conference").
    var title: Text? {
        switch kind {
        case .driver: Text("Drivers")
        case .constructor: Text("Constructors")
        case .team: name.map { Text(verbatim: $0) }
        }
    }
}

nonisolated extension Set<String> {
    /// True when these full follow keys cover `row` — its full id, or a
    /// colon-anchored suffix match on its raw provider team id.
    func containsFollowedTeam(for row: SportsStandingRow) -> Bool {
        if contains(row.id) {
            return true
        }
        guard let teamId = row.teamId, !teamId.isEmpty else { return false }
        return contains { $0.hasSuffix(":\(teamId)") }
    }
}

/// The subtle highlight band behind a followed team's standings cells.
@ViewBuilder
func standingsRowHighlight(_ followed: Bool) -> some View {
    if followed {
        Color.primary.opacity(0.08)
    }
}

/// Adds a tap gesture only when an action is supplied, so a read-only table
/// stays non-interactive rather than swallowing scroll gestures.
private struct TapToSelect: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

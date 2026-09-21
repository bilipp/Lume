//
//  TVGameDetailSections.swift
//  Lume
//
//  The focusable channel row, the Timeline / Stats / Lineup pill selector and the
//  tvOS-scaled renderers that TVGameDetailSheet drops below its header and Watch
//  card. They are split out of TVGameDetailSheet to keep each file under the
//  line cap. `TVChannelRow` (LiveTVTVComponents) and the phone Timeline / Stats /
//  Lineup sections (GameDetailSections) are both `private` and modelled for their
//  own screens, so these are purpose-built 10-foot variants that render the same
//  `SportsEventDetail` and `ResolvedChannel` value types.
//

#if os(tvOS)

    import SwiftUI

    // MARK: - Channel row

    /// A focusable Watch row for the channels a fixture resolved to. Mirrors the
    /// phone sheet's row (logo, name + quality badge, `HH:mm · programme`, play)
    /// but adopts the tvOS focus idiom: a white-wash lift on focus via
    /// `TVCardButtonStyle`.
    struct TVSportsChannelRow: View {
        let channel: ResolvedChannel
        let onPlay: () -> Void

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            Button(action: onPlay) {
                HStack(spacing: 22) {
                    ChannelLogo(urlString: channel.stream.streamIcon, size: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        name
                        subtitle
                    }
                    Spacer(minLength: 16)
                    Image(systemName: "play.circle.fill").font(.system(size: 40))
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isFocused ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.white.opacity(0.06)))
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.03))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Watch on \(channel.stream.name)"))
        }

        private var name: some View {
            HStack(spacing: 10) {
                Text(verbatim: channel.stream.name)
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(1)
                if let badge = sportsQualityBadge(from: channel.stream.name) {
                    Text(verbatim: badge)
                        .font(.system(size: 18, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }
        }

        @ViewBuilder
        private var subtitle: some View {
            if let subtitle = channel.matchedSubtitle {
                subtitle
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Pill chrome

    /// The rest/focus chrome the hub's filter row gives every control: a
    /// translucent wash at rest, solid white with black text on focus. Padding
    /// and radius match `TVSportsPillLabel` so a Menu label, a plain Button and
    /// the segmented pills line up as one row.
    struct TVSportsPillChrome<Content: View>: View {
        @ViewBuilder var content: () -> Content
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            content()
                .foregroundStyle(isFocused ? .black : .white)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.08)))
                )
        }
    }

    // MARK: - Focusable content

    /// tvOS only scrolls to what can take focus, so long read-only content is
    /// made focusable in rows (a timeline event, a stat) or blocks (a lineup, the
    /// standings). A soft wash marks the focused item without lifting it.
    private struct TVFocusRow: ViewModifier {
        var cornerRadius: CGFloat = 14
        var horizontalPadding: CGFloat = 16
        var verticalPadding: CGFloat = 10
        @FocusState private var isFocused: Bool

        func body(content: Content) -> some View {
            content
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.white.opacity(isFocused ? 0.14 : 0))
                )
                .focusable()
                .focused($isFocused)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }

    extension View {
        /// A focusable read-only row with a soft highlight on focus.
        func tvFocusRow() -> some View {
            modifier(TVFocusRow())
        }

        /// A focusable read-only block (card) with a soft highlight on focus.
        func tvFocusBlock() -> some View {
            modifier(TVFocusRow(cornerRadius: 20, horizontalPadding: 24, verticalPadding: 24))
        }
    }

    extension Array {
        /// Consecutive slices of at most `size` elements, in order.
        func chunked(into size: Int) -> [[Element]] {
            guard size > 0 else { return [self] }
            return stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
        }
    }

    // MARK: - Tab pill

    /// The Sports Hub's tvOS pill look — solid white with black text on focus, a
    /// translucent wash while selected — shared by the game-detail tab selector
    /// and `TVSportsHubScreen`'s filter segmented control. The caller supplies
    /// `isFocused` (from `@Environment(\.isFocused)` or a parent `@FocusState`) so
    /// either focus model can drive it, kept off any layout so focus never sizes
    /// the view.
    struct TVSportsPillLabel: View {
        let title: LocalizedStringKey
        let font: Font
        let isFocused: Bool
        let isActive: Bool
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let cornerRadius: CGFloat

        var body: some View {
            Text(title)
                .font(font)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .foregroundStyle(foreground)
                .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill))
        }

        private var foreground: Color {
            if isFocused { return .black }
            return isActive ? .white : .white.opacity(0.5)
        }

        private var fill: AnyShapeStyle {
            if isFocused { return AnyShapeStyle(.white) }
            return isActive ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.clear)
        }
    }

    /// A focusable pill in the Timeline / Stats / Lineup selector.
    struct TVTabPill: View {
        let title: LocalizedStringKey
        let isActive: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                PillLabel(title: title, isActive: isActive)
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.04))
        }

        private struct PillLabel: View {
            let title: LocalizedStringKey
            let isActive: Bool
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                TVSportsPillLabel(
                    title: title,
                    font: .system(size: 26, weight: .semibold),
                    isFocused: isFocused,
                    isActive: isActive,
                    horizontalPadding: 32,
                    verticalPadding: 16,
                    cornerRadius: 14
                )
            }
        }
    }

    // MARK: - Timeline

    struct TVTimelineSection: View {
        let events: [SportsKeyEvent]
        let fixture: SportsFixture

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                    row(event)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func row(_ event: SportsKeyEvent) -> some View {
            HStack(alignment: .top, spacing: 18) {
                Text(verbatim: event.clock)
                    .font(.system(size: 24, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(minWidth: 70, alignment: .leading)
                icon(event).frame(width: 28)
                crest(for: event.teamId)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: event.localizedTitle)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                    if !event.participants.isEmpty {
                        Text(verbatim: event.participants.joined(separator: ", "))
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 0)
            }
            .tvFocusRow()
            .accessibilityElement(children: .combine)
        }

        @ViewBuilder
        private func icon(_ event: SportsKeyEvent) -> some View {
            if event.isGoal {
                Image(systemName: "soccerball").font(.system(size: 24)).foregroundStyle(.white)
            } else if event.isCard {
                RoundedRectangle(cornerRadius: 3).fill(cardColor(event)).frame(width: 18, height: 24)
            } else if event.isSubstitution {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 22)).foregroundStyle(.green)
            } else {
                Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.5))
            }
        }

        private func cardColor(_ event: SportsKeyEvent) -> Color {
            event.isYellowCard ? .yellow : .red
        }

        private func crest(for teamId: String?) -> some View {
            SportsTimelineCrest(fixture: fixture, teamId: teamId, crestSize: 30, dotSize: 18)
        }
    }

    // MARK: - Stats

    struct TVStatsSection: View {
        let stats: [SportsTeamStat]
        let homePalette: TeamPalette
        let awayPalette: TeamPalette

        var body: some View {
            VStack(spacing: 22) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                    statRow(stat)
                }
            }
        }

        private func statRow(_ stat: SportsTeamStat) -> some View {
            VStack(spacing: 10) {
                Text(verbatim: stat.localizedName)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 18) {
                    Text(verbatim: stat.homeDisplay)
                        .font(.system(size: 26, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 90, alignment: .leading)
                    bar(stat)
                    Text(verbatim: stat.awayDisplay)
                        .font(.system(size: 26, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 90, alignment: .trailing)
                }
            }
            .tvFocusRow()
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
                let usable = max(0, geo.size.width - 4)
                if total > 0 {
                    HStack(spacing: 4) {
                        Capsule()
                            .fill(homePalette.primary)
                            .frame(width: max(4, CGFloat(home / total) * usable))
                        Capsule()
                            .fill(awayPalette.primary)
                            .frame(width: max(4, CGFloat(away / total) * usable))
                    }
                } else {
                    Capsule().fill(.white.opacity(0.2))
                }
            }
            .frame(height: 12)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Lineup

    struct TVLineupSection: View {
        let lineups: [SportsLineup]
        let fixture: SportsFixture

        var body: some View {
            HStack(alignment: .top, spacing: 60) {
                ForEach(Array(lineups.enumerated()), id: \.offset) { _, lineup in
                    teamLineup(lineup)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func teamLineup(_ lineup: SportsLineup) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if let team = team(for: lineup.teamId) {
                        TeamCrest(team: team, size: 34)
                            .accessibilityHidden(true)
                        Text(verbatim: team.name).font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                    }
                    Spacer(minLength: 0)
                    if let formation = lineup.formation, !formation.isEmpty {
                        Text(verbatim: formation)
                            .font(.system(size: 24, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                ForEach(Array(lineup.starters.enumerated()), id: \.offset) { _, player in
                    playerRow(player)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tvFocusBlock()
        }

        private func playerRow(_ player: SportsLineupPlayer) -> some View {
            HStack(spacing: 14) {
                Text(verbatim: player.jersey ?? "")
                    .font(.system(size: 22, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(minWidth: 34, alignment: .trailing)
                Text(verbatim: player.name)
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if let position = player.position, !position.isEmpty {
                    Text(verbatim: position)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .accessibilityElement(children: .combine)
        }

        private func team(for teamId: String) -> SportsTeam? {
            fixture.team(forTeamId: teamId)
        }
    }
#endif

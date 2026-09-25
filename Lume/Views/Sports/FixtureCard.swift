//
//  FixtureCard.swift
//  Lume
//
//  One fixture in the Sports Hub: a rounded glass card washed with a subtle
//  diagonal home→away team-colour gradient. Left column is the kickoff time
//  (or LIVE / FT) and the competition crest; the middle stacks the two
//  teams (crest + name, the followed one starred, the winner bold and the loser
//  dimmed); the right shows the score once there is one. A live fixture with a
//  single confident channel gets a one-tap play glyph; every card taps through
//  to the game detail. A single merged context menu carries the long-press
//  actions — it is built here, once, so nothing nested re-declares it.
//

import SwiftUI

struct FixtureCard: View {
    let fixture: SportsFixture
    let resolved: [ResolvedChannel]
    let isFollowed: (SportsTeam) -> Bool
    /// Off inside a section that is already one competition (a league group on
    /// Today, a league-scoped hub, a league's own screen), where the crest
    /// would only repeat the header.
    var showsLeagueMark = true
    /// Off under a day header (the hub's Upcoming list, a league's fixtures),
    /// where the date would only repeat it. A headline that falls on a different
    /// day than the fixture's start — a race weekend's Sunday race — names its
    /// day regardless.
    var showsDate = true
    var onOpenDetail: () -> Void
    var onWatch: (ResolvedChannel) -> Void
    var onFollowToggle: (SportsTeam) -> Void
    var onPickChannel: () -> Void

    /// Two crest rows — the tallest thing a card's middle can hold — so an event
    /// card (a race, a fight night) with its two text lines stands as tall as a
    /// two-team card beside it in the Home rail.
    @ScaledMetric(relativeTo: .subheadline) private var contentMinHeight: CGFloat = 52
    @AppStorage(SportsSyncService.hideScoresKey) private var hidesScores = false

    /// The lone confident channel a live card offers one-tap playback for.
    private var confidentChannel: ResolvedChannel? {
        guard fixture.isInProgress else { return nil }
        return resolved.first { $0.isConfident }
    }

    /// Whether the status column names the day: whenever the headline is not
    /// today (unless the surrounding section already says so), and always when
    /// the headline falls on a different day than the fixture's own start.
    private var showsDateLine: Bool {
        fixture.headlineIsOnAnotherDay || (showsDate && !fixture.headlineIsToday)
    }

    var body: some View {
        Button(action: onOpenDetail) {
            content
                // The Button reads its label from this single element, so VoiceOver
                // hears one card, not the card plus an auto-combined duplicate.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
        }
        .buttonStyle(.plain)
        .fixtureWatchAction(channel: confidentChannel, channelName: confidentChannel?.stream.name ?? "", onWatch: onWatch)
        .contextMenu { menu }
    }

    // MARK: - Card body

    private var content: some View {
        HStack(spacing: 14) {
            statusColumn
                .frame(width: 64)

            if fixture.hasTeams {
                teamRows
            } else {
                eventRow
            }

            Spacer(minLength: 0)

            trailing
        }
        .frame(maxWidth: .infinity, minHeight: contentMinHeight)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(gradient, in: RoundedRectangle(cornerRadius: 16))
        .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private var gradient: LinearGradient {
        TeamPalette.gradient(home: fixture.homePalette, away: fixture.awayPalette)
    }

    // MARK: - Left column

    private var statusColumn: some View {
        VStack(spacing: 4) {
            switch fixture.status.state {
            case .inProgress:
                LiveBadge(fontSize: 10)
                if let line = fixture.status.liveDetail(family: fixture.periodFamily, hidingScores: hidesScores) {
                    Text(verbatim: line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .final:
                EndedBadge(fontSize: 10)
                if showsDateLine {
                    dateLine
                }
            case .postponed:
                Text(verbatim: fixture.status.localizedStoppage)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            case .scheduled:
                if showsDateLine {
                    dateLine
                }
                if fixture.startTimeIsTentative == true {
                    Text("TBD")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text(fixture.headlineDate, format: .dateTime.hour().minute())
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            if showsLeagueMark {
                leagueMark
            }
        }
    }

    /// "Sat 27 Sep" — the day a fixture that is not today's belongs to.
    private var dateLine: some View {
        Text(fixture.headlineDate, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    /// The competition's crest; its abbreviation only when no crest is known.
    /// This is the card's one league mark — the event row draws none — so a
    /// Formula 1 session never shows the same logo twice.
    @ViewBuilder
    private var leagueMark: some View {
        if let logo = fixture.leagueLogoURL ?? SportsCatalog.league(id: fixture.leagueId)?.logoURL {
            LeagueCrest(url: logo, size: 18)
                .padding(.top, 2)
        } else {
            Text(fixture.leagueAbbreviation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    // MARK: - Middle

    private var teamRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tournament = fixture.tournamentLine {
                Text(verbatim: tournament)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let home = fixture.home {
                teamRow(home)
            }
            if let away = fixture.away {
                teamRow(away)
            }
        }
    }

    private func teamRow(_ competitor: SportsCompetitor) -> some View {
        HStack(spacing: 8) {
            TeamCrest(team: competitor.team, size: 22)
            Text(competitor.team.name)
                .font(.subheadline)
                .fontWeight(rowWeight(competitor))
                .foregroundStyle(rowColor(competitor))
                .lineLimit(1)
            if isFollowed(competitor.team) {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
        }
    }

    /// A competitor-less event: a session card shows the session over the
    /// Grand Prix; a fight night or a race weekend shows its name over its venue.
    private var eventRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let kind = fixture.sessionKind {
                    Text(kind.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(verbatim: fixture.eventTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(verbatim: fixture.eventTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let subtitle = fixture.eventSubtitle {
                        Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    /// A finished game bolds the winner and dims the loser; a live or scheduled
    /// game keeps both level, and so does any game while scores are hidden.
    private func rowWeight(_ competitor: SportsCompetitor) -> Font.Weight {
        guard fixture.status.state == .final, !hidesScores else { return .regular }
        return competitor.isWinner ? .bold : .regular
    }

    private func rowColor(_ competitor: SportsCompetitor) -> Color {
        guard fixture.status.state == .final, !hidesScores, !competitor.isWinner,
              fixture.home?.isWinner == true || fixture.away?.isWinner == true
        else { return .primary }
        return .secondary
    }

    // MARK: - Right

    private var trailing: some View {
        HStack(spacing: 10) {
            // A race or a fight night has no two-sided score to show.
            if fixture.hasTeams, !hidesScores, fixture.status.state == .inProgress || fixture.status.state == .final {
                VStack(alignment: .trailing, spacing: 8) {
                    // Holds the tournament caption's line so the scores stay
                    // level with the player rows beside them.
                    if fixture.tournamentLine != nil {
                        Text(verbatim: " ").font(.caption2).hidden()
                    }
                    Text(verbatim: fixture.home?.displayScore ?? "0")
                        .fontWeight(rowWeight(fixture.home ?? SportsCompetitor(team: placeholderTeam)))
                    Text(verbatim: fixture.away?.displayScore ?? "0")
                        .fontWeight(rowWeight(fixture.away ?? SportsCompetitor(team: placeholderTeam)))
                }
                .font(fixture.hasTextScores || fixture.hasSetScores ? .subheadline : .title3)
                .monospacedDigit()
                .lineLimit(1)
            }

            if let confidentChannel {
                Button {
                    onWatch(confidentChannel)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Watch"))
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var placeholderTeam: SportsTeam {
        SportsTeam(leagueId: fixture.leagueId, teamId: "", name: "", shortName: "", abbreviation: "")
    }

    // MARK: - Accessibility

    /// A single spoken line for the whole card: the matchup, the status (with the
    /// score for a live or finished game), and the competition — e.g. "Bayern
    /// versus Union Berlin, Live, 2 to 1, 63', Bundesliga". Team and league names
    /// come from the provider verbatim.
    private var accessibilityLabel: Text {
        var parts: [String] = []
        if let home = fixture.home?.team, let away = fixture.away?.team {
            parts.append(String(localized: "\(home.name) versus \(away.name)"))
        } else {
            if let kind = fixture.sessionKind { parts.append(String(localized: kind.displayName)) }
            parts.append(fixture.eventTitle)
        }
        switch fixture.status.state {
        case .scheduled:
            if fixture.startTimeIsTentative == true {
                if showsDateLine { parts.append(fixture.headlineDate.formatted(date: .abbreviated, time: .omitted)) }
                parts.append(String(localized: "Time to be decided"))
            } else {
                parts.append(fixture.headlineDate.formatted(
                    date: showsDateLine ? .abbreviated : .omitted, time: .shortened
                ))
            }
        case .inProgress:
            parts.append(String(localized: "Live"))
            if fixture.hasTeams, !hidesScores { parts.append(scoreSpokenLine) }
            if let line = fixture.status.liveDetail(family: fixture.periodFamily, hidingScores: hidesScores) {
                parts.append(line)
            }
        case .final:
            parts.append(String(localized: "Final"))
            if showsDateLine { parts.append(fixture.headlineDate.formatted(date: .abbreviated, time: .omitted)) }
            if fixture.hasTeams, !hidesScores {
                parts.append(scoreSpokenLine)
                if let qualifier = fixture.status.localizedEndingQualifier(family: fixture.periodFamily) { parts.append(qualifier) }
            }
        case .postponed:
            parts.append(fixture.status.localizedStoppage)
        }
        parts.append(fixture.tournamentLine ?? fixture.leagueName)
        return Text(verbatim: parts.joined(separator: ", "))
    }

    private var scoreSpokenLine: String {
        fixture.setsLine ?? String(localized: "\(fixture.home?.displayScore ?? "0") to \(fixture.away?.displayScore ?? "0")")
    }

    // MARK: - Context menu

    @ViewBuilder
    private var menu: some View {
        if let confidentChannel {
            Button {
                onWatch(confidentChannel)
            } label: {
                Label("Watch", systemImage: "play.fill")
            }
        }
        Button {
            onOpenDetail()
        } label: {
            Label("Open Detail", systemImage: "info.circle")
        }
        if let home = fixture.home?.team {
            Button {
                onFollowToggle(home)
            } label: {
                Label(followLabel(home), systemImage: isFollowed(home) ? "star.slash" : "star")
            }
        }
        if let away = fixture.away?.team {
            Button {
                onFollowToggle(away)
            } label: {
                Label(followLabel(away), systemImage: isFollowed(away) ? "star.slash" : "star")
            }
        }
        if !resolved.isEmpty {
            Button {
                onPickChannel()
            } label: {
                Label("Pick Channel…", systemImage: "tv.badge.wifi")
            }
        }
    }

    private func followLabel(_ team: SportsTeam) -> String {
        let name = team.shortName.isEmpty ? team.name : team.shortName
        return isFollowed(team)
            ? String(localized: "Unfollow \(name)")
            : String(localized: "Follow \(name)")
    }
}

private extension View {
    /// Exposes the confident channel's one-tap playback as a VoiceOver custom
    /// action on the combined card element, so the card still opens on a
    /// double-tap while "Watch on <channel>" stays reachable from the rotor.
    @ViewBuilder
    func fixtureWatchAction(
        channel: ResolvedChannel?,
        channelName: String,
        onWatch: @escaping (ResolvedChannel) -> Void
    ) -> some View {
        if let channel {
            accessibilityAction(named: Text("Watch on \(channelName)")) { onWatch(channel) }
        } else {
            self
        }
    }
}

// MARK: - Shared artwork

/// A team crest with a real (non-`EmptyView`) placeholder — a monogram tile —
/// so `CachedAsyncImage`'s load task fires and a missing logo still reads.
struct TeamCrest: View {
    let team: SportsTeam
    var size: CGFloat

    var body: some View {
        CachedAsyncImage(url: team.logoURL, maxPixelSize: size * 2) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFit()
            default:
                placeholder
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: size * 0.2)
            .fill(.quaternary)
            .overlay(
                Text(monogram)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.secondary)
            )
    }

    private var monogram: String {
        let source = team.abbreviation.isEmpty ? team.name : team.abbreviation
        return String(source.prefix(3)).uppercased()
    }
}

/// A channel logo with a real placeholder tile, matching `TeamCrest`.
struct ChannelLogo: View {
    let urlString: String?
    var size: CGFloat

    var body: some View {
        CachedAsyncImage(url: URL(string: urlString ?? ""), maxPixelSize: size * 2) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFit()
            default:
                RoundedRectangle(cornerRadius: size * 0.2)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "tv").font(.system(size: size * 0.4)).foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

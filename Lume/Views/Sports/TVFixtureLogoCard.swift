//
//  TVFixtureLogoCard.swift
//  Lume
//
//  The one tvOS fixture card, on the Home rail and in the hub: the two crests
//  with the kickoff time or the score between them — a 10-foot glance, not a
//  line of text. Team names live on the detail screen. The team gradient stays
//  at rest; focus is a scale lift (TVCardButtonStyle) plus a white ring, since
//  the system white-fill idiom would paint the gradient over.
//

#if os(tvOS)

    import SwiftUI

    struct TVFixtureLogoCard: View {
        let fixture: SportsFixture
        /// Off inside a rail that is already one competition, where the crest
        /// would only repeat the rail's heading.
        var showsLeagueMark = true
        var onSelect: () -> Void
        @AppStorage(SportsSyncService.hideScoresKey) private var hidesScores = false

        var body: some View {
            Button(action: onSelect) {
                TVFixtureLogoCardContent(fixture: fixture, showsLeagueMark: showsLeagueMark, showsScore: !hidesScores)
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: fixture.tvSpokenSummary(showsScore: !hidesScores)))
        }
    }

    extension SportsFixture {
        /// One spoken line for a whole card — the matchup, the status (with the
        /// score for a live or finished game) and the competition. Team and league
        /// names come from the provider verbatim. Shared by the hub card and the
        /// Home rail's crest card.
        func tvSpokenSummary(showsScore: Bool) -> String {
            var parts: [String] = []
            if let home = home?.team, let away = away?.team {
                parts.append(String(localized: "\(home.name) versus \(away.name)"))
            } else {
                if let sessionKind { parts.append(String(localized: sessionKind.displayName)) }
                parts.append(eventTitle)
            }
            let score = String(localized: "\(home?.displayScore ?? "0") to \(away?.displayScore ?? "0")")
            switch status.state {
            case .scheduled:
                parts.append(headlineDate.formatted(
                    date: headlineIsOnAnotherDay || !headlineIsToday ? .abbreviated : .omitted, time: .shortened
                ))
            case .inProgress:
                parts.append(String(localized: "Live"))
                if hasTeams, showsScore { parts.append(score) }
                if let line = status.liveDetail(family: periodFamily, hidingScores: !showsScore) { parts.append(line) }
            case .final:
                parts.append(String(localized: "Final"))
                if hasTeams, showsScore {
                    parts.append(score)
                    if let qualifier = status.localizedEndingQualifier(family: periodFamily) { parts.append(qualifier) }
                }
            case .postponed:
                parts.append(status.localizedStoppage)
            }
            parts.append(tournamentLine ?? leagueName)
            return parts.joined(separator: ", ")
        }
    }

    private struct TVFixtureLogoCardContent: View {
        let fixture: SportsFixture
        let showsLeagueMark: Bool
        let showsScore: Bool
        @Environment(\.isFocused) private var isFocused

        /// The header line pins to the top on every card so a row of mixed team
        /// and event cards lines up; the crests centre in the space below it.
        var body: some View {
            VStack(spacing: 0) {
                topLine
                if let home = fixture.home, let away = fixture.away {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        side(home).frame(maxWidth: .infinity)
                        centre.frame(width: 120)
                        side(away).frame(maxWidth: .infinity)
                    }
                    Spacer(minLength: 0)
                } else {
                    eventLine
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(width: 320, height: 200)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .overlay(TeamPalette.gradient(home: fixture.homePalette, away: fixture.awayPalette))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(isFocused ? 1 : 0.1), lineWidth: isFocused ? 4 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }

        /// The competition's crest (its abbreviation only when no crest is
        /// known; nothing in a single-league rail), then the status at the
        /// trailing edge.
        private var topLine: some View {
            HStack(spacing: 8) {
                if !showsLeagueMark {
                    EmptyView()
                } else if let logo = fixture.leagueLogoURL ?? SportsCatalog.league(id: fixture.leagueId)?.logoURL {
                    LeagueCrest(url: logo, size: 26)
                } else {
                    Text(verbatim: fixture.leagueAbbreviation)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                switch fixture.status.state {
                case .inProgress:
                    LiveBadge(fontSize: 17)
                case .final:
                    EndedBadge(fontSize: 17)
                case .postponed:
                    Text("PP").font(.callout.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                case .scheduled:
                    EmptyView()
                }
            }
            // A scheduled card in a single-league rail has nothing on this line;
            // hold its height so the crests stay level with the neighbours'.
            .frame(minHeight: 26)
        }

        /// A team's crest; a tennis player's flag with their name under it, since
        /// two players from one country would otherwise look alike.
        @ViewBuilder
        private func side(_ competitor: SportsCompetitor) -> some View {
            if fixture.hasSetScores {
                VStack(spacing: 8) {
                    TeamCrest(team: competitor.team, size: 60)
                    Text(verbatim: competitor.team.shortName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                TeamCrest(team: competitor.team, size: 88)
            }
        }

        /// Kickoff time before the game; the score once it is live or over, or
        /// a plain "vs" while scores are hidden.
        @ViewBuilder
        private var centre: some View {
            switch fixture.status.state {
            case .inProgress, .final:
                if showsScore {
                    Text(verbatim: fixture.scoreLine)
                        .font(.system(size: fixture.hasTextScores ? 26 : 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text("vs")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
            case .scheduled, .postponed:
                if fixture.startTimeIsTentative == true {
                    Text("TBD")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Text(fixture.startDate, format: .dateTime.hour().minute())
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
        }

        /// Competitor-less events, left-aligned so the card reads top-down: the
        /// session (or the event's short name) as the title, the Grand Prix as a
        /// quiet second line, then the time. Sizes are fixed rather than text
        /// styles — tvOS's `title3` alone would spill a three-line stack out of a
        /// 200pt card.
        private var eventLine: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let kind = fixture.sessionKind {
                    Text(kind.displayName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(verbatim: fixture.eventShortTitle)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                } else {
                    Text(verbatim: fixture.eventShortTitle)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text(
                    fixture.headlineDate,
                    format: fixture.headlineIsOnAnotherDay || !fixture.headlineIsToday
                        ? .dateTime.weekday(.abbreviated).hour().minute()
                        : .dateTime.hour().minute()
                )
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
#endif

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
        var onSelect: () -> Void

        var body: some View {
            Button(action: onSelect) {
                TVFixtureLogoCardContent(fixture: fixture)
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: fixture.tvSpokenSummary))
        }
    }

    extension SportsFixture {
        /// One spoken line for a whole card — the matchup, the status (with the
        /// score for a live or finished game) and the competition. Team and league
        /// names come from the provider verbatim. Shared by the hub card and the
        /// Home rail's crest card.
        var tvSpokenSummary: String {
            var parts: [String] = []
            if let home = home?.team, let away = away?.team {
                parts.append(String(localized: "\(home.name) versus \(away.name)"))
            } else {
                parts.append(eventTitle)
            }
            let score = String(localized: "\(home?.score ?? 0) to \(away?.score ?? 0)")
            switch status.state {
            case .scheduled:
                parts.append(headlineDate.formatted(
                    date: headlineIsOnAnotherDay ? .abbreviated : .omitted, time: .shortened
                ))
            case .inProgress:
                parts.append(String(localized: "Live"))
                if hasTeams { parts.append(score) }
                if !status.shortDetail.isEmpty { parts.append(status.shortDetail) }
            case .final:
                parts.append(String(localized: "Final"))
                if hasTeams { parts.append(score) }
            case .postponed:
                parts.append(String(localized: "Postponed"))
            }
            parts.append(leagueName)
            return parts.joined(separator: ", ")
        }
    }

    private struct TVFixtureLogoCardContent: View {
        let fixture: SportsFixture
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            VStack(spacing: 18) {
                topLine
                if let home = fixture.home, let away = fixture.away {
                    HStack(spacing: 0) {
                        TeamCrest(team: home.team, size: 88).frame(maxWidth: .infinity)
                        centre.frame(width: 120)
                        TeamCrest(team: away.team, size: 88).frame(maxWidth: .infinity)
                    }
                } else {
                    eventLine
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

        private var topLine: some View {
            HStack {
                Text(verbatim: fixture.leagueAbbreviation)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 8)
                switch fixture.status.state {
                case .inProgress:
                    Text("LIVE").font(.callout.weight(.heavy)).foregroundStyle(.red)
                case .final:
                    Text("FT").font(.callout.weight(.bold)).foregroundStyle(.white.opacity(0.8))
                case .postponed:
                    Text("PP").font(.callout.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                case .scheduled:
                    EmptyView()
                }
            }
        }

        /// Kickoff time before the game; the score once it is live or over.
        @ViewBuilder
        private var centre: some View {
            switch fixture.status.state {
            case .inProgress, .final:
                Text(verbatim: "\(fixture.home?.score ?? 0) – \(fixture.away?.score ?? 0)")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            case .scheduled, .postponed:
                Text(fixture.startDate, format: .dateTime.hour().minute())
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }

        /// Competitor-less events (a race weekend, a fight night): the event name
        /// and its time.
        private var eventLine: some View {
            VStack(spacing: 10) {
                Text(verbatim: fixture.eventShortTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(
                    fixture.headlineDate,
                    format: fixture.headlineIsOnAnotherDay
                        ? .dateTime.weekday(.abbreviated).hour().minute()
                        : .dateTime.hour().minute()
                )
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxHeight: .infinity)
        }
    }
#endif

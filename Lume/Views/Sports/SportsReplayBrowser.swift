//
//  SportsReplayBrowser.swift
//  Lume
//
//  League / season / phase / week navigation over the same replay values. A
//  missing level is skipped instead of inventing competition metadata.
//

import SwiftUI

/// The season browser's levels, outermost first. A level a league has no
/// metadata for collapses into the next one.
enum SportsReplayLevel: Int {
    case league, season, phase, week, game

    var next: Self {
        Self(rawValue: rawValue + 1) ?? .game
    }
}

struct SportsReplayBrowser<Card: View>: View {
    let games: [SportsReplayGame]
    var level = SportsReplayLevel.league
    @ViewBuilder var card: (SportsReplayGame) -> Card

    private var groups: [(key: String, games: [SportsReplayGame])] {
        Dictionary(grouping: games) { key($0.fixture) }
            .map { (key: $0.key, games: $0.value) }
            .sorted {
                switch level {
                case .season: (Int($0.key) ?? 0) > (Int($1.key) ?? 0)
                case .week: (Int($0.key) ?? 0) < (Int($1.key) ?? 0)
                default: $0.key.localizedStandardCompare($1.key) == .orderedAscending
                }
            }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if level == .game {
                ForEach(games) { card($0) }
            } else {
                ForEach(groups, id: \.key) { group in
                    if group.key.isEmpty {
                        SportsReplayBrowser(games: group.games, level: level.next, card: card)
                    } else {
                        NavigationLink {
                            ScrollView {
                                SportsReplayBrowser(games: group.games, level: level.next, card: card)
                                    .padding()
                            }
                            .navigationTitle(title(group.games.first?.fixture))
                        } label: {
                            HStack {
                                Text(verbatim: title(group.games.first?.fixture))
                                Spacer()
                                Text(verbatim: String(group.games.count)).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").accessibilityHidden(true)
                            }
                            .frame(minHeight: 44)
                            .padding()
                        }
                    }
                }
            }
        }
    }

    private func key(_ fixture: SportsFixture) -> String {
        switch level {
        case .league: fixture.leagueId
        case .season: fixture.seasonYear.map(String.init) ?? ""
        case .phase: fixture.seasonPhase ?? ""
        case .week: fixture.week.map(String.init) ?? ""
        case .game: ""
        }
    }

    private func title(_ fixture: SportsFixture?) -> String {
        guard let fixture else { return "" }
        switch level {
        case .league: return fixture.leagueName
        case .season: return fixture.seasonName ?? fixture.seasonYear.map(String.init) ?? ""
        case .phase: return fixture.seasonPhase ?? ""
        case .week:
            if let label = fixture.weekLabel { return label }
            return fixture.week.map { String(localized: "Week \($0)") } ?? ""
        case .game: return ""
        }
    }
}

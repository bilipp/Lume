//
//  SportsReplayBrowser.swift
//  Lume
//
//  League / season / phase / week navigation over the same replay values. A
//  missing level is skipped instead of inventing competition metadata.
//

import SwiftUI

struct SportsReplayBrowser<Card: View>: View {
    let games: [SportsReplayGame]
    var depth = 0
    @ViewBuilder var card: (SportsReplayGame) -> Card

    private var groups: [(key: String, games: [SportsReplayGame])] {
        Dictionary(grouping: games) { key($0.fixture) }
            .map { (key: $0.key, games: $0.value) }
            .sorted {
                if depth == 1 { return (Int($0.key) ?? 0) > (Int($1.key) ?? 0) }
                if depth == 3 { return (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
                return $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if depth >= 4 {
                ForEach(games) { card($0) }
            } else {
                ForEach(groups, id: \.key) { group in
                    if group.key.isEmpty {
                        SportsReplayBrowser(games: group.games, depth: depth + 1, card: card)
                    } else {
                        NavigationLink {
                            ScrollView {
                                SportsReplayBrowser(games: group.games, depth: depth + 1, card: card)
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
        switch depth {
        case 0: fixture.leagueId
        case 1: fixture.seasonYear.map(String.init) ?? ""
        case 2: fixture.seasonPhase ?? ""
        case 3: fixture.week.map(String.init) ?? ""
        default: ""
        }
    }

    private func title(_ fixture: SportsFixture?) -> String {
        guard let fixture else { return "" }
        switch depth {
        case 0: return fixture.leagueName
        case 1: return fixture.seasonName ?? fixture.seasonYear.map(String.init) ?? ""
        case 2: return fixture.seasonPhase ?? ""
        case 3:
            if let label = fixture.weekLabel { return label }
            return fixture.week.map { String(localized: "Week \($0)") } ?? ""
        default: return ""
        }
    }
}

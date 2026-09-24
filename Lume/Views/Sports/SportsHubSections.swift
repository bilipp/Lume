//
//  SportsHubSections.swift
//  Lume
//
//  The Sports Hub's sectioned body, its onboarding card and its "no games"
//  state, split out of `SportsHubView` to keep each file small. The hub does the
//  fixture assembly and hands finished `SportsFixtureGroup`s down; this file only
//  renders them — a thin rule header per group, then the `FixtureCard`s — and
//  routes the card's actions back up through closures.
//

import SwiftUI

/// One rendered section: a league (with a chevron to scope the hub to it), the
/// "My Teams" band, or a day in the Upcoming list.
struct SportsFixtureGroup: Identifiable {
    let id: String
    let title: String
    let logoURL: URL?
    /// Non-nil for a league group — the chevron scopes the hub to this league.
    let leagueId: String?
    let fixtures: [SportsFixture]
    /// True when every card in the group belongs to one competition the header
    /// already names, so the cards drop their own league crest as noise. The
    /// "My Teams" band and the Upcoming days mix leagues and keep it.
    var isSingleLeague = false
    /// True for a group under a day header (Today / Tomorrow / "Saturday, 27 Sep"),
    /// where the cards drop their own date line as noise.
    var isGroupedByDay = false

    /// Groups fixtures by calendar day, newest header first, for the Upcoming
    /// list. Each group's title is Today / Tomorrow / a "weekday, d MMM" line.
    static func byDay(_ fixtures: [SportsFixture], calendar: Calendar = .current) -> [SportsFixtureGroup] {
        let grouped = Dictionary(grouping: fixtures) { calendar.startOfDay(for: $0.startDate) }
        return grouped.keys.sorted().map { day in
            SportsFixtureGroup(
                id: ISO8601DateFormatter.dayKey(day),
                title: Self.dayLabel(day, calendar: calendar),
                logoURL: nil,
                leagueId: nil,
                fixtures: (grouped[day] ?? []).sorted(by: SportsFixture.displayOrder),
                isGroupedByDay: true
            )
        }
    }

    static func dayLabel(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

private extension ISO8601DateFormatter {
    static func dayKey(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }
}

// MARK: - Sections

struct SportsSectionsView: View {
    let groups: [SportsFixtureGroup]
    let resolved: [String: [ResolvedChannel]]
    let isFollowed: (SportsTeam) -> Bool
    var onOpenDetail: (SportsFixture) -> Void
    var onWatch: (ResolvedChannel) -> Void
    var onFollowToggle: (SportsTeam) -> Void
    var onPickChannel: (SportsFixture) -> Void
    var onSelectLeague: (String) -> Void

    var body: some View {
        if groups.isEmpty {
            SportsNoGamesView()
        } else {
            ForEach(groups) { group in
                section(for: group)
            }
        }
    }

    private func section(for group: SportsFixtureGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(for: group)
            ForEach(group.fixtures) { card(for: $0, in: group) }
        }
    }

    private func card(for fixture: SportsFixture, in group: SportsFixtureGroup) -> some View {
        FixtureCard(
            fixture: fixture,
            resolved: resolved[fixture.id] ?? [],
            isFollowed: isFollowed,
            showsLeagueMark: !group.isSingleLeague,
            showsDate: !group.isGroupedByDay,
            onOpenDetail: { onOpenDetail(fixture) },
            onWatch: onWatch,
            onFollowToggle: onFollowToggle,
            onPickChannel: { onPickChannel(fixture) }
        )
    }

    @ViewBuilder
    private func header(for group: SportsFixtureGroup) -> some View {
        if let leagueId = group.leagueId {
            Button {
                onSelectLeague(leagueId)
            } label: {
                headerLabel(for: group, chevron: true)
            }
            .buttonStyle(.plain)
        } else {
            headerLabel(for: group, chevron: false)
        }
    }

    private func headerLabel(for group: SportsFixtureGroup, chevron: Bool) -> some View {
        HStack(spacing: 8) {
            if let logoURL = group.logoURL {
                CachedAsyncImage(url: logoURL, maxPixelSize: 24) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            }
            Text(group.title)
                .font(.headline)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1).offset(y: 6)
        }
        .padding(.bottom, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - No games

struct SportsNoGamesView: View {
    var body: some View {
        Text("No games")
            .font(.headline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }
}

// MARK: - Onboarding

struct SportsOnboardingCard: View {
    var onManageTeams: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Follow Your Teams", systemImage: "sportscourt")
        } description: {
            Text("Add leagues and teams to see fixtures, live scores and standings, with one tap to the channel carrying the game.")
        } actions: {
            Button {
                onManageTeams()
            } label: {
                Label("Manage Teams", systemImage: "person.2.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

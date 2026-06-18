//
//  SportAnnouncementsRow.swift
//  Lume
//
//  The Home "Upcoming Matches" rail. Fetches fixtures for the user's favorite
//  leagues / teams (SportAnnouncementsService) and resolves each to a channel in
//  the active playlist's EPG (SportMatcher), so a match can be tapped to tune in.
//  Renders nothing until there's at least one upcoming fixture, like the other
//  Home rails.
//

import SwiftData
import SwiftUI

/// A fixture paired with the channel that carries it, when one was found.
private struct ResolvedSportMatch: Identifiable {
    let fixture: SportFixture
    let stream: LiveStream?

    var id: String {
        fixture.id
    }

    var channelName: String? {
        stream?.name
    }
}

struct SportAnnouncementsRow: View {
    /// The active playlist, used to scope EPG/channel matching. May be nil before
    /// the user has any playlist (the row then simply shows nothing).
    let playlist: Playlist?
    let onPlay: (LiveStream) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SportFavorite.addedAt) private var favorites: [SportFavorite]
    @State private var service = SportAnnouncementsService.shared
    @State private var matches: [ResolvedSportMatch] = []

    private var leagueIDs: [String] {
        favorites.filter { $0.kind == .league }.map(\.externalID)
    }

    private var teamIDs: [String] {
        favorites.filter { $0.kind == .team }.map(\.externalID)
    }

    var body: some View {
        Group {
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Upcoming Matches")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: SportCardMetrics.spacing) {
                            ForEach(matches) { match in
                                card(for: match)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, SportCardMetrics.verticalPadding)
                    }
                    .scrollClipDisabled()
                }
            }
        }
        .task(id: reloadKey) {
            await service.refresh(leagueIDs: leagueIDs, teamIDs: teamIDs)
            resolveMatches()
        }
    }

    @ViewBuilder
    private func card(for match: ResolvedSportMatch) -> some View {
        if let stream = match.stream {
            Button {
                onPlay(stream)
            } label: {
                SportMatchCard(fixture: match.fixture, channelName: match.channelName)
            }
            .posterCardButtonStyle()
        } else {
            // No channel found in the user's EPG — still worth announcing, just
            // not tappable.
            SportMatchCard(fixture: match.fixture, channelName: nil)
        }
    }

    /// Re-run when the favorites or the active playlist change. The fixture fetch
    /// itself is cached by the service, so this is cheap on no-op changes.
    private var reloadKey: String {
        let favs = favorites.map(\.id).sorted().joined(separator: ",")
        return "\(playlist?.id.uuidString ?? "none")|\(favs)"
    }

    // MARK: - Resolution (the hybrid: fixture → EPG program → channel)

    private func resolveMatches() {
        let fixtures = service.fixtures
        guard !fixtures.isEmpty else {
            matches = []
            return
        }

        let channelMap = channelsByEPGID()
        let candidates = candidatePrograms(channelIds: Set(channelMap.keys), fixtures: fixtures)

        matches = fixtures.map { fixture in
            let stream = SportMatcher.bestMatch(for: fixture, in: candidates)
                .flatMap { channelMap[$0.channelId] }
            return ResolvedSportMatch(fixture: fixture, stream: stream)
        }
    }

    /// EPG-id → channel for the active playlist's non-hidden channels that carry
    /// guide data. Keyed by `epgChannelId`, which is what EPG listings reference.
    private func channelsByEPGID() -> [String: LiveStream] {
        let descriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.epgChannelId != nil && !$0.isHidden }
        )
        let streams = (try? modelContext.fetch(descriptor)) ?? []
        let prefix = playlist.map { "\($0.id.uuidString)-" }
        var map: [String: LiveStream] = [:]
        for stream in streams {
            guard let channelId = stream.epgChannelId else { continue }
            if let prefix, !stream.id.hasPrefix(prefix) { continue }
            if map[channelId] == nil { map[channelId] = stream }
        }
        return map
    }

    /// EPG programs on the user's channels within the fixtures' time span, mapped
    /// to the matcher's value type.
    private func candidatePrograms(channelIds: Set<String>, fixtures: [SportFixture]) -> [EPGProgramCandidate] {
        guard !channelIds.isEmpty, let maxKickoff = fixtures.map(\.kickoff).max() else { return [] }
        let windowStart = Date().addingTimeInterval(-SportMatcher.leadTime)
        let windowEnd = maxKickoff.addingTimeInterval(3 * 3600)
        let descriptor = FetchDescriptor<EPGListing>(
            predicate: #Predicate { $0.start >= windowStart && $0.start <= windowEnd }
        )
        let listings = (try? modelContext.fetch(descriptor)) ?? []
        return listings
            .filter { channelIds.contains($0.channelId) }
            .map {
                EPGProgramCandidate(
                    channelId: $0.channelId,
                    title: $0.title,
                    listingDescription: $0.listingDescription,
                    start: $0.start,
                    end: $0.end
                )
            }
    }
}

// MARK: - Card

private enum SportCardMetrics {
    #if os(tvOS)
        static let width: CGFloat = 460
        static let spacing: CGFloat = 36
        static let verticalPadding: CGFloat = 28
        static let cornerRadius: CGFloat = 16
    #else
        static let width: CGFloat = 250
        static let spacing: CGFloat = 14
        static let verticalPadding: CGFloat = 4
        static let cornerRadius: CGFloat = 14
    #endif
}

/// A landscape card announcing one match: the competition, the matchup, the
/// kickoff time and — when matched — the channel it's on.
private struct SportMatchCard: View {
    let fixture: SportFixture
    let channelName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(fixture.leagueName.isEmpty ? String(localized: "Football") : fixture.leagueName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tint)
                .lineLimit(1)

            Text(fixture.matchup)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Label(kickoffLabel, systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let channelName {
                Label(channelName, systemImage: "play.tv")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            } else {
                Label("Not in your channels", systemImage: "tv.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(width: SportCardMetrics.width, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: SportCardMetrics.cornerRadius))
    }

    /// "Today · 17:30", "Tomorrow · 21:00", or "Sat · 15:00" — localized.
    private var kickoffLabel: String {
        let time = fixture.kickoff.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(fixture.kickoff) {
            return "\(String(localized: "Today")) · \(time)"
        }
        if calendar.isDateInTomorrow(fixture.kickoff) {
            return "\(String(localized: "Tomorrow")) · \(time)"
        }
        let day = fixture.kickoff.formatted(.dateTime.weekday(.abbreviated))
        return "\(day) · \(time)"
    }
}

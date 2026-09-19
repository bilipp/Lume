//
//  ChannelPickerSheet.swift
//  Lume
//
//  The channel picker a fixture's long-press "Pick Channel…" opens when the game
//  is carried on more than one of the viewer's channels. It lists the same
//  resolved rows as the game-detail Watch card — channel logo, name, a quality
//  badge parsed from the name, and a "HH:mm · programme title" second line —
//  titled "Home – Away". Choosing a row both starts playback (through the
//  caller's `onWatch`) and remembers the pick device-locally in
//  `SportsChannelPicks`, so the resolver floats that channel to the top for
//  every future fixture in the same competition.
//

import SwiftUI

struct ChannelPickerSheet: View {
    let fixture: SportsFixture
    let resolved: [ResolvedChannel]
    var onWatch: (ResolvedChannel) -> Void
    /// Device-local picks store; injectable for tests, `.standard` otherwise.
    var picks = SportsChannelPicks()

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if resolved.isEmpty {
                    emptyState
                } else {
                    Section {
                        ForEach(resolved) { channel in
                            Button {
                                select(channel)
                            } label: {
                                SportsChannelRow(channel: channel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(Text(verbatim: title))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .channelPickerPlatformChrome()
    }

    // MARK: - Empty state

    private var emptyState: some View {
        SportsEmptyChannelsView()
    }

    // MARK: - Selection

    private func select(_ channel: ResolvedChannel) {
        picks.remember(
            competitionKey: fixture.leagueId,
            channelKey: SportsChannelPicks.channelKey(
                epgChannelId: channel.stream.epgChannelId, name: channel.stream.name
            ),
            playlistID: channel.playlistID
        )
        onWatch(channel)
    }

    // MARK: - Derived

    /// "Home – Away" from the two team names, or the competition name for a
    /// competitor-less event (which the picker is not normally opened for).
    private var title: String {
        if let home = fixture.home?.team, let away = fixture.away?.team {
            let homeName = home.shortName.isEmpty ? home.name : home.shortName
            let awayName = away.shortName.isEmpty ? away.name : away.shortName
            return "\(homeName) – \(awayName)"
        }
        return fixture.leagueName
    }
}

// MARK: - Shared channel row

/// One resolved-channel row: logo, name with a quality badge, and a
/// "HH:mm · programme title" second line when the EPG match is known. Reused for
/// the picker; the trailing play glyph signals that a tap starts playback.
struct SportsChannelRow: View {
    let channel: ResolvedChannel

    var body: some View {
        HStack(spacing: 12) {
            ChannelLogo(urlString: channel.stream.streamIcon, size: 36)
            SportsChannelLabel(channel: channel)
            Spacer(minLength: 8)
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

/// The name line (with quality badge) stacked over the "HH:mm · programme"
/// subtitle. Shared by `SportsChannelRow` and the game-detail single-channel CTA
/// so the two never drift.
struct SportsChannelLabel: View {
    let channel: ResolvedChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            nameLine
            subtitleLine
        }
    }

    private var nameLine: some View {
        HStack(spacing: 6) {
            Text(verbatim: channel.stream.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let badge = sportsQualityBadge(from: channel.stream.name) {
                Text(verbatim: badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var subtitleLine: some View {
        if let subtitle = channel.matchedSubtitle {
            subtitle
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Pulls a quality tag out of a channel name — "DAZN 1 FHD", "Sky 4K UHD".
/// Checks the most specific tokens first so "4K UHD" reports "4K".
nonisolated func sportsQualityBadge(from name: String) -> String? {
    let haystack = name.uppercased()
    for token in ["4K", "UHD", "FHD", "HD"] where haystack.contains(token) {
        return token
    }
    return nil
}

extension ResolvedChannel {
    /// The "HH:mm · programme" second line (or just the time, or just the title)
    /// for the matched EPG programme; `nil` when nothing is known. Callers apply
    /// their own font and colour and a single-line limit.
    var matchedSubtitle: Text? {
        if let start = matchedStart {
            if let title = matchedTitle, !title.isEmpty {
                return Text(start, format: .dateTime.hour().minute()) + Text(verbatim: " · \(title)")
            }
            return Text(start, format: .dateTime.hour().minute())
        }
        if let title = matchedTitle, !title.isEmpty {
            return Text(verbatim: title)
        }
        return nil
    }
}

/// The "Not in your channels" empty state shared by the game-detail Watch card
/// and the channel picker.
struct SportsEmptyChannelsView: View {
    var body: some View {
        Text("Not in your channels")
            .font(titleFont)
            .foregroundStyle(titleColor)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(tvOS)
        private var titleFont: Font {
            .system(size: 28)
        }

        private var titleColor: AnyShapeStyle {
            AnyShapeStyle(.white.opacity(0.6))
        }
    #else
        private var titleFont: Font {
            .subheadline
        }

        private var titleColor: AnyShapeStyle {
            AnyShapeStyle(.secondary)
        }
    #endif
}

private extension View {
    /// Per-platform sheet chrome kept in one `#if` so SwiftFormat cannot
    /// reindent adjacent conditionals in the modifier chain. A `List` in a
    /// frameless macOS sheet collapses, so the frame is mandatory there.
    @ViewBuilder
    func channelPickerPlatformChrome() -> some View {
        #if os(macOS)
            frame(minWidth: 420, minHeight: 480)
        #elseif os(iOS)
            presentationDetents([.medium, .large])
        #else
            self
        #endif
    }
}

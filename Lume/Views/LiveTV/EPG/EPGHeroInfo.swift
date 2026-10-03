//
//  EPGHeroInfo.swift
//  Lume
//
//  The tvOS Guide hero's left-hand block: the channel the viewer is on and
//  what it is airing now. It follows the focused row on every press, while
//  the picture beside it waits for the preview to settle.
//

#if os(tvOS)
    import SwiftUI

    /// The only reader of `GuideHeroModel.focusedRow`, so a press
    /// re-renders this block and nothing above it.
    struct EPGHeroInfo: View {
        let hero: GuideHeroModel?
        /// Described while focus is outside the guide.
        let settled: EPGChannelRow?

        @Environment(\.epgHeroLayout) private var layout

        var body: some View {
            if let channel = hero?.focusedRow ?? settled {
                TimelineView(.everyMinute) { context in
                    EPGHeroInfoContent(channel: channel, now: context.date, isCompact: layout.isCompact)
                }
            }
        }
    }

    private struct EPGHeroInfoContent: View {
        let channel: EPGChannelRow
        let now: Date
        /// The small hero: a smaller title and no separate time line (the
        /// progress row and Up next still place the programme in time).
        let isCompact: Bool

        private static let tertiary = Color.white.opacity(0.58)
        private static let meta = Color.white.opacity(0.7)

        var body: some View {
            let current = GuidePreviewPolicy.currentProgramme(in: channel.cells, at: now)
            let next = GuidePreviewPolicy.nextProgramme(in: channel.cells, after: now)

            VStack(alignment: .leading, spacing: 0) {
                header

                Group {
                    if let current {
                        Text(current.title)
                    } else {
                        Text("No programme information")
                    }
                }
                .font(.system(size: isCompact ? 32 : 40, weight: .bold))
                .tracking(-0.4)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, isCompact ? 14 : 20)

                if let current {
                    if !isCompact {
                        Text(current.start ..< current.end, format: .interval.hour().minute())
                            .font(.system(size: 24))
                            .foregroundStyle(Self.meta)
                            .lineLimit(1)
                            .padding(.top, 10)
                    }

                    progress(of: current)
                        .padding(.top, isCompact ? 14 : 18)
                }

                if let next {
                    Text("Up next · \(next.start, format: .dateTime.hour().minute()) \(next.title)")
                        .font(.system(size: 20))
                        .foregroundStyle(Self.tertiary)
                        .lineLimit(1)
                        .padding(.top, isCompact ? 8 : 10)
                }
            }
            .foregroundStyle(.white)
        }

        private var header: some View {
            HStack(spacing: 16) {
                EPGTVLogoTile(url: channel.logoURL, side: 56, cornerRadius: 14, padding: 6, glyphSize: 22)

                Text(channel.name)
                    .font(.system(size: 23, weight: .semibold))
                    .lineLimit(1)

                LiveBadge(fontSize: 17)
                    .padding(.leading, 8)
            }
        }

        private func progress(of programme: EPGProgramCell) -> some View {
            HStack(spacing: 16) {
                EPGTVProgressBar(
                    progress: programme.progress(at: now),
                    track: .white.opacity(0.18),
                    fill: LiveTVPalette.accent,
                    height: 6
                )
                .frame(width: 360)

                Text("\(GuidePreviewPolicy.minutesLeft(of: programme, at: now)) min left")
                    .font(.system(size: 20))
                    .foregroundStyle(Self.meta)
                    .lineLimit(1)
            }
        }
    }
#endif

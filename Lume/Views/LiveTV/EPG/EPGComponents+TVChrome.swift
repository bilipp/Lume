//
//  EPGComponents+TVChrome.swift
//  Lume
//
//  The tvOS guide's chrome around the programme blocks: the channel cell, the
//  time ruler with its now pill, the date over the channel column, and the
//  hint under the guide. Touch and pointer platforms keep `EPGChannelCell`
//  and `EPGTimeRuler`.
//

import SwiftUI

#if os(tvOS)
    extension EPGColors {
        /// Text on the guide's white focus cards.
        static let ink = Color(.sRGB, red: 11 / 255, green: 13 / 255, blue: 18 / 255)
        static let inkSecondary = Color(.sRGB, red: 58 / 255, green: 64 / 255, blue: 76 / 255)
        /// The guide's white focus card and its edge.
        static let cardFill = Color.white.opacity(0.96)
        static let cardBorder = Color.white.opacity(0.6)
        /// Text on the accent now pill.
        static let onAccent = Color(.sRGB, red: 6 / 255, green: 18 / 255, blue: 31 / 255)
    }

    // MARK: - Channel cell

    /// How the guide's virtual focus touches a channel's row.
    enum EPGChannelCellHighlight {
        case none
        /// A programme in the row is focused.
        case row
        /// The channel itself — the hub — is focused.
        case hub
    }

    /// The tvOS channel column entry: logo tile, name and channel number. The
    /// focused hub is the same white card as a focused programme; while one of
    /// the row's programmes is focused the cell lifts to mark the row.
    struct EPGTVChannelCell: View {
        let row: EPGChannelRow
        let metrics: EPGMetrics
        var highlight = EPGChannelCellHighlight.none

        private static let logoSide: CGFloat = 46

        private var isHub: Bool {
            highlight == .hub
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            HStack(spacing: 14) {
                logo
                Text(row.name)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(isHub ? EPGColors.ink : .white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if row.catchupCapable {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isHub ? EPGColors.ink : LiveTVPalette.accent)
                        .accessibilityLabel(Text("Catch-up available"))
                }
                if let number = row.number {
                    Text(number, format: .number.grouping(.never))
                        .font(.system(size: 19))
                        .foregroundStyle(isHub ? EPGColors.inkSecondary : .white.opacity(0.55))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 16)
            .frame(width: metrics.channelColumnWidth, height: metrics.rowHeight, alignment: .leading)
            .background(fill, in: shape)
            .overlay {
                shape.strokeBorder(border, lineWidth: 1)
            }
        }

        private var fill: Color {
            switch highlight {
            case .hub: EPGColors.cardFill
            case .row: .white.opacity(0.15)
            case .none: .white.opacity(0.05)
            }
        }

        private var border: Color {
            switch highlight {
            case .hub: EPGColors.cardBorder
            case .row: .white.opacity(0.24)
            case .none: .white.opacity(0.08)
            }
        }

        /// A dark tile in every state, so a white logo stays visible on the
        /// hub's white card.
        private var logo: some View {
            EPGTVLogoTile(url: row.logoURL, side: Self.logoSide, cornerRadius: 12, padding: 5, glyphSize: 18)
        }
    }

    /// A dark logo tile, so a white logo stays visible. Never an `EmptyView`
    /// in any phase: the image loads from a `.task` on its content.
    struct EPGTVLogoTile: View {
        let url: URL?
        let side: CGFloat
        let cornerRadius: CGFloat
        let padding: CGFloat
        let glyphSize: CGFloat

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            CachedAsyncImage(url: url, maxPixelSize: LiveTVLogo.pixelSize) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFit().padding(padding)
                case .failure:
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: glyphSize))
                        .foregroundStyle(.white.opacity(0.6))
                default:
                    Color.clear
                }
            }
            .frame(width: side, height: side)
            .background(Color(white: 0.16), in: shape)
            .clipShape(shape)
        }
    }

    // MARK: - Time ruler

    /// The time axis: a label every half hour; a new day adds its short date
    /// so a 24-hour window stays unambiguous.
    struct EPGTVTimeRuler: View {
        let timeline: EPGTimeline
        let metrics: EPGMetrics
        /// Observed for `mirror` (moves) and `window` (block crossings).
        let sync: EPGScrollSync

        var body: some View {
            let mirrorX = sync.mirror.x
            let ticks = timeline.halfHourTicks(from: sync.window.start - metrics.pointsPerMinute * 30, to: sync.window.end)
            // Moves with the now line, which ticks every minute; the labels the
            // pill would cover step aside with it.
            TimelineView(.everyMinute) { context in
                ZStack(alignment: .leading) {
                    ForEach(ticks, id: \.self) { tick in
                        label(tick)
                            .opacity(EPGTimeline.tickIsCoveredByNowPill(tick, now: context.date) ? 0 : 1)
                            .offset(x: timeline.x(for: tick) - mirrorX)
                    }
                    EPGTVNowPill(date: context.date, height: metrics.headerHeight)
                        .offset(x: timeline.x(for: context.date) - mirrorX)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }

        private func label(_ date: Date) -> some View {
            let calendar = Calendar.current
            let isMidnight = calendar.component(.hour, from: date) == 0 && calendar.component(.minute, from: date) == 0
            return HStack(spacing: 8) {
                Text(date, format: .dateTime.hour().minute())
                if isMidnight {
                    Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .font(.system(size: 20))
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(1)
        }
    }

    /// The current time in the accent, centred over the now line.
    struct EPGTVNowPill: View {
        let date: Date
        let height: CGFloat

        var body: some View {
            Text(date, format: .dateTime.hour().minute())
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(EPGColors.onAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(LiveTVPalette.accent))
                .fixedSize()
                .frame(height: height)
                // Zero-width and centred on its point: an alignment guide
                // would widen the ruler's stack leftwards by half the pill
                // and push every label off its tick.
                .frame(width: 0)
        }
    }

    /// "Today · Fri 2 Oct" over the channel column.
    struct EPGTVRulerCorner: View {
        let date: Date

        var body: some View {
            Text("Today · \(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))")
                .font(.system(size: 19))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    // MARK: - Hint

    /// What the channel hub's long press offers, which nothing on screen
    /// would otherwise reveal. Never focusable.
    struct EPGGuideHint: View {
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "smallcircle.filled.circle")
                    .font(.system(size: 16))
                    .accessibilityHidden(true)
                Text("Hold a channel to add it to Favorites or Multi-View")
            }
            .font(.system(size: 17))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            .padding(.leading, 16)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
#endif

//
//  EPGComponents.swift
//  Lume
//
//  The shared building blocks of the guide grid: per-platform metrics, the time
//  ruler, the channel cell, the programme block, and the "now" indicator. These
//  are reused by both the touch/pointer scroller and the tvOS focus scroller.
//

import SwiftUI

// MARK: - Palette

/// Explicit guide colours. The app ships an empty `AccentColor` asset, so
/// `Color.accentColor` resolves to *white* on tvOS — which renders a focused
/// block as white text on a white fill. The 10-foot UI therefore uses these
/// concrete colours and the system "focused = solid white, dark text" idiom
/// (mirroring `TVGlassButtonStyle`) instead of the accent colour.
enum EPGColors {
    /// Tint for the currently-airing programme (progress bar + live accents).
    static let live = Color.blue
}

// MARK: - Metrics

/// Platform-tuned sizing for the guide. The 10-foot UI needs far larger touch
/// targets and type than a phone or a pointer-driven window.
struct EPGMetrics {
    var pointsPerMinute: CGFloat
    var rowHeight: CGFloat
    var rowSpacing: CGFloat
    var channelColumnWidth: CGFloat
    var headerHeight: CGFloat
    var blockCornerRadius: CGFloat
    var blockInset: CGFloat
    /// How much of the programme already in progress stays visible when the
    /// guide parks on "now": enough to show where the current show started —
    /// and the tail of the one before it — rather than only what is still to
    /// come. The 10-foot layout fits hours across the screen, so it needs a
    /// wider lead-in than a phone to read as the same amount of context.
    var nowLeadInMinutes: CGFloat
    /// The gap between the channel column and the programme track.
    var channelColumnGap: CGFloat
    /// A focused programme's height; taller than `rowHeight` where the
    /// focused card overflows its row.
    var focusedBlockHeight: CGFloat

    static var current: EPGMetrics {
        #if os(tvOS)
            let channelColumnWidth: CGFloat = 340
            let channelColumnGap: CGFloat = 12
            // Two hours across the track beside the category rail.
            let trackWidth = TVLiveTVLayout.paneWidth - channelColumnWidth - channelColumnGap
            return EPGMetrics(
                pointsPerMinute: trackWidth / 120,
                rowHeight: 70,
                // The design's 8 pt gap plus its 2 pt row margin.
                rowSpacing: 10,
                channelColumnWidth: channelColumnWidth,
                headerHeight: 36,
                blockCornerRadius: 16,
                blockInset: 18,
                nowLeadInMinutes: 10,
                channelColumnGap: channelColumnGap,
                focusedBlockHeight: 80
            )
        #elseif os(macOS)
            EPGMetrics(
                pointsPerMinute: 3.4,
                rowHeight: 58,
                rowSpacing: 4,
                channelColumnWidth: 210,
                headerHeight: 36,
                blockCornerRadius: 7,
                blockInset: 10,
                nowLeadInMinutes: 10,
                channelColumnGap: 0,
                focusedBlockHeight: 58
            )
        #else
            EPGMetrics(
                pointsPerMinute: 3.0,
                rowHeight: 68,
                rowSpacing: 4,
                channelColumnWidth: 136,
                headerHeight: 36,
                blockCornerRadius: 9,
                blockInset: 10,
                nowLeadInMinutes: 10,
                channelColumnGap: 0,
                focusedBlockHeight: 68
            )
        #endif
    }
}

// MARK: - Time ruler

#if !os(tvOS)
    /// The horizontal time axis. Half-hour marks with the hour emphasised; a new
    /// day prints its short date so a 24-hour window stays unambiguous. tvOS has
    /// its own, `EPGTVTimeRuler`.
    struct EPGTimeRuler: View {
        let timeline: EPGTimeline
        let metrics: EPGMetrics

        private var slotWidth: CGFloat {
            metrics.pointsPerMinute * 30
        }

        var body: some View {
            HStack(spacing: 0) {
                ForEach(timeline.halfHourTicks, id: \.self) { tick in
                    tickLabel(tick)
                        .frame(width: slotWidth, alignment: .leading)
                }
            }
            .frame(height: metrics.headerHeight)
        }

        @ViewBuilder
        private func tickLabel(_ date: Date) -> some View {
            let isHour = Calendar.current.component(.minute, from: date) == 0
            let isMidnight = isHour && Calendar.current.component(.hour, from: date) == 0

            HStack(spacing: 6) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: isHour ? metrics.headerHeight * 0.5 : metrics.headerHeight * 0.3)

                VStack(alignment: .leading, spacing: 0) {
                    Text(date, format: .dateTime.hour().minute())
                        .font(isHour ? .subheadline.weight(.semibold) : .caption)
                        .foregroundStyle(isHour ? .primary : .secondary)
                    if isMidnight {
                        Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
#endif

// MARK: - Channel cell

#if !os(tvOS)
    /// The frozen left-column entry for a channel: logo + name. Opaque so programme
    /// blocks scrolling underneath stay hidden. tvOS has its own,
    /// `EPGTVChannelCell`.
    struct EPGChannelCell: View {
        let row: EPGChannelRow
        let metrics: EPGMetrics

        var body: some View {
            HStack(spacing: 10) {
                logo
                Text(row.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Flag channels with an archive so the viewer knows the row
                // offers replays — same idiom as the player's channel overlay.
                if row.catchupCapable {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .accessibilityLabel(Text("Catch-up available"))
                }
            }
            .padding(.horizontal, 12)
            .frame(width: metrics.channelColumnWidth, height: metrics.rowHeight, alignment: .leading)
            .background(.background)
            .overlay(alignment: .trailing) {
                Rectangle().fill(.quaternary).frame(width: 1)
            }
        }

        private var logo: some View {
            CachedAsyncImage(url: row.logoURL, maxPixelSize: 76) { phase in
                switch phase {
                case .empty:
                    placeholder.overlay { ProgressView().controlSize(.small) }
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fit)
                case .failure:
                    placeholder.overlay {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                @unknown default:
                    placeholder
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }

        private var placeholder: some View {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.fill.tertiary)
        }
    }
#endif

// MARK: - Programme block

#if !os(tvOS)
    /// A single programme in the grid. Live programmes are tinted and carry a
    /// progress bar; past programmes are dimmed — except replayable ones (inside
    /// the channel's catch-up archive), which stay brighter and carry a replay
    /// glyph; gaps are inert.
    struct EPGProgramBlockView: View {
        let cell: EPGProgramCell
        let metrics: EPGMetrics
        let now: Date
        let isFocused: Bool
        var canReplay = false

        private var isLive: Bool {
            cell.isLive(at: now)
        }

        private var isPast: Bool {
            cell.isPast(at: now)
        }

        /// Hairline gap between adjacent blocks. Applied as inset *inside* the
        /// cell's exact width so tiling stays pixel-aligned across rows.
        private var gap: CGFloat {
            metrics.rowSpacing
        }

        var body: some View {
            ZStack(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cell.isGap ? "No Programme" : cell.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(lineLimit)

                    if showsTime {
                        HStack(spacing: 4) {
                            if canReplay {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            Text(cell.start, format: .dateTime.hour().minute())
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, metrics.blockInset)
                .padding(.vertical, metrics.blockInset * 0.55)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Keeps the text of a partially scrolled block readable; see
                // `EPGStickyText` for why this is a `visualEffect`.
                .visualEffect { [inset = metrics.blockInset] content, proxy in
                    content.offset(
                        x: EPGStickyText.shift(
                            blockMinX: proxy.frame(in: .scrollView).minX,
                            blockWidth: proxy.size.width,
                            inset: inset
                        )
                    )
                }

                if isLive {
                    liveProgressBar
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: metrics.blockCornerRadius, style: .continuous))
            .opacity(cell.isGap ? 0.5 : (isPast && !isFocused ? (canReplay ? 0.8 : 0.55) : 1))
            .padding(.trailing, gap)
            .padding(.vertical, gap / 2)
            .frame(width: cell.width, height: metrics.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }

        /// The block is wide enough to show a start time alongside the title.
        private var showsTime: Bool {
            !cell.isGap && cell.width > metrics.channelColumnWidth * 0.55
        }

        private var lineLimit: Int {
            cell.width > metrics.channelColumnWidth ? 2 : 1
        }

        @ViewBuilder
        private var background: some View {
            let shape = RoundedRectangle(cornerRadius: metrics.blockCornerRadius, style: .continuous)
            if cell.isGap {
                shape.fill(.fill.quaternary)
            } else {
                if isFocused {
                    shape.fill(Color.accentColor)
                } else if isLive {
                    shape.fill(Color.accentColor.opacity(0.18))
                        .overlay {
                            shape.strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                        }
                } else {
                    shape.fill(.fill.tertiary)
                }
            }
        }

        private var liveProgressBar: some View {
            GeometryReader { geo in
                Capsule()
                    .fill(progressTint)
                    .frame(width: geo.size.width * cell.progress(at: now), height: 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 3)
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        }

        private var progressTint: Color {
            isFocused ? .white : .accentColor
        }

        private var titleColor: Color {
            if cell.isGap { return .secondary }
            return isFocused ? .white : .primary
        }
    }

    /// Wraps a programme block in its selection affordance: a press dip on touch
    /// and pointer, a lift under keyboard focus. Builds the visual from the cell
    /// so the block can react to focus (which is only observable from inside a
    /// style).
    struct EPGBlockButtonStyle: ButtonStyle {
        let cell: EPGProgramCell
        let metrics: EPGMetrics
        let now: Date
        var canReplay = false

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(cell: cell, metrics: metrics, now: now, canReplay: canReplay, isPressed: configuration.isPressed)
        }

        private struct StyleBody: View {
            let cell: EPGProgramCell
            let metrics: EPGMetrics
            let now: Date
            let canReplay: Bool
            let isPressed: Bool
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                let focused = isFocused
                let scale = focused ? 1.04 : (isPressed ? 0.97 : 1.0)
                // Radius 0 when unfocused: a transparent radius-10 shadow still
                // sits in the render tree of every realized cell, and hundreds of
                // shadowed cells is what made focus-scrolling stutter (#27).
                EPGProgramBlockView(cell: cell, metrics: metrics, now: now, isFocused: focused, canReplay: canReplay)
                    .shadow(color: .black.opacity(0.4), radius: focused ? 10 : 0, y: focused ? 6 : 0)
                    .scaleEffect(scale)
                    .animation(.easeOut(duration: 0.18), value: focused)
                    .animation(.easeOut(duration: 0.12), value: isPressed)
            }
        }
    }
#endif

// MARK: - Now indicator

/// The vertical "now" line drawn over the grid content. A small cap at the top
/// marks the current moment on the ruler; on tvOS the ruler's pill does.
struct EPGNowIndicator: View {
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(lineColor)
                .frame(width: 2)
            #if !os(tvOS)
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .offset(y: -4)
            #endif
        }
        .frame(width: 9, height: height, alignment: .top)
    }

    private var lineColor: Color {
        #if os(tvOS)
            LiveTVPalette.accent.opacity(0.85)
        #else
            .red
        #endif
    }
}

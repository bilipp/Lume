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

    static var current: EPGMetrics {
        #if os(tvOS)
            EPGMetrics(
                pointsPerMinute: 6,
                rowHeight: 116,
                rowSpacing: 14,
                channelColumnWidth: 300,
                headerHeight: 68,
                blockCornerRadius: 16,
                blockInset: 18
            )
        #elseif os(macOS)
            EPGMetrics(
                pointsPerMinute: 3.4,
                rowHeight: 58,
                rowSpacing: 4,
                channelColumnWidth: 210,
                headerHeight: 36,
                blockCornerRadius: 7,
                blockInset: 10
            )
        #else
            EPGMetrics(
                pointsPerMinute: 3.0,
                rowHeight: 68,
                rowSpacing: 4,
                channelColumnWidth: 136,
                headerHeight: 36,
                blockCornerRadius: 9,
                blockInset: 10
            )
        #endif
    }
}

// MARK: - Time ruler

/// The horizontal time axis. Half-hour marks with the hour emphasised; a new
/// day prints its short date so a 24-hour window stays unambiguous.
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
                    .font(epgFont(hour: isHour))
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

    private func epgFont(hour: Bool) -> Font {
        #if os(tvOS)
            return .system(size: 24, weight: hour ? .semibold : .regular)
        #else
            return hour ? .subheadline.weight(.semibold) : .caption
        #endif
    }
}

// MARK: - Channel cell

/// The frozen left-column entry for a channel: logo + name. Opaque so programme
/// blocks scrolling underneath (on touch platforms) stay hidden.
struct EPGChannelCell: View {
    let row: EPGChannelRow
    let metrics: EPGMetrics

    var body: some View {
        HStack(spacing: 10) {
            logo
            Text(row.name)
                .font(nameFont)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        #if os(tvOS)
            .frame(width: metrics.channelColumnWidth, height: metrics.rowHeight, alignment: .leading)
            .background(
                .white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        #else
            .frame(width: metrics.channelColumnWidth, height: metrics.rowHeight, alignment: .leading)
                .background(.background)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(.quaternary).frame(width: 1)
                }
        #endif
    }

    private var logoSide: CGFloat {
        #if os(tvOS)
            72
        #else
            38
        #endif
    }

    private var logo: some View {
        CachedAsyncImage(url: row.logoURL, maxPixelSize: logoSide * 2) { phase in
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
        .frame(width: logoSide, height: logoSide)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.fill.tertiary)
    }

    private var nameFont: Font {
        #if os(tvOS)
            .system(size: 24, weight: .semibold)
        #else
            .subheadline.weight(.medium)
        #endif
    }
}

// MARK: - Programme block

/// A single programme in the grid. Live programmes are tinted and carry a
/// progress bar; past programmes are dimmed; gaps are inert.
struct EPGProgramBlockView: View {
    let cell: EPGProgramCell
    let metrics: EPGMetrics
    let now: Date
    let isFocused: Bool

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
                    .font(titleFont)
                    .foregroundStyle(titleColor)
                    .lineLimit(lineLimit)

                if showsTime {
                    Text(cell.start, format: .dateTime.hour().minute())
                        .font(timeFont)
                        .foregroundStyle(timeColor)
                }
            }
            .padding(.horizontal, metrics.blockInset)
            .padding(.vertical, metrics.blockInset * 0.55)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if isLive {
                liveProgressBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: metrics.blockCornerRadius, style: .continuous))
        .opacity(cell.isGap ? 0.5 : (isPast && !isFocused ? 0.55 : 1))
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
            #if os(tvOS)
                // Gaps are focusable so a no-EPG channel can still be selected;
                // give the focused gap a light fill + border so the focus lands
                // visibly, without the heavy solid-white fill a programme gets.
                if isFocused {
                    shape.fill(.white.opacity(0.18))
                        .overlay { shape.strokeBorder(.white.opacity(0.6), lineWidth: 1.5) }
                } else {
                    shape.fill(.fill.quaternary)
                }
            #else
                shape.fill(.fill.quaternary)
            #endif
        } else {
            #if os(tvOS)
                // tvOS uses the system focus idiom (solid white fill, dark text)
                // and translucent surfaces that sit lightly on the dark backdrop,
                // matching the channel list rather than a heavy opaque grid.
                if isFocused {
                    shape.fill(.white)
                } else if isLive {
                    shape.fill(.white.opacity(0.16))
                        .overlay {
                            shape.strokeBorder(EPGColors.live.opacity(0.55), lineWidth: 1.5)
                        }
                } else {
                    shape.fill(.white.opacity(0.08))
                }
            #else
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
            #endif
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
        #if os(tvOS)
            // A coloured bar stays readable on both the translucent and the
            // focused (white) fill; a white bar would vanish on the latter.
            return EPGColors.live
        #else
            return isFocused ? .white : .accentColor
        #endif
    }

    private var titleColor: Color {
        if cell.isGap { return .secondary }
        #if os(tvOS)
            return isFocused ? .black : .white
        #else
            return isFocused ? .white : .primary
        #endif
    }

    private var timeColor: Color {
        #if os(tvOS)
            return isFocused ? .black.opacity(0.6) : .white.opacity(0.6)
        #else
            return .secondary
        #endif
    }

    private var titleFont: Font {
        #if os(tvOS)
            .system(size: 25, weight: .semibold)
        #else
            .subheadline.weight(.semibold)
        #endif
    }

    private var timeFont: Font {
        #if os(tvOS)
            .system(size: 20)
        #else
            .caption2
        #endif
    }
}

/// Wraps a programme block in the platform's selection affordance: a focus lift
/// on tvOS, a press dip on touch/pointer. Builds the visual from the cell so the
/// block can react to focus (which is only observable from inside a style).
struct EPGBlockButtonStyle: ButtonStyle {
    let cell: EPGProgramCell
    let metrics: EPGMetrics
    let now: Date

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(cell: cell, metrics: metrics, now: now, isPressed: configuration.isPressed)
    }

    private struct StyleBody: View {
        let cell: EPGProgramCell
        let metrics: EPGMetrics
        let now: Date
        let isPressed: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let scale = isFocused ? 1.04 : (isPressed ? 0.97 : 1.0)
            EPGProgramBlockView(cell: cell, metrics: metrics, now: now, isFocused: isFocused)
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 10, y: 6)
                .scaleEffect(scale)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: isPressed)
        }
    }
}

// MARK: - Now indicator

/// The vertical "now" line drawn over the grid content. A small cap at the top
/// marks the current moment on the ruler.
struct EPGNowIndicator: View {
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 2)
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .offset(y: -4)
        }
        .frame(width: 9, height: height, alignment: .top)
    }
}

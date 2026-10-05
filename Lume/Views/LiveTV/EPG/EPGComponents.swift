//
//  EPGComponents.swift
//  Lume
//
//  The shared building blocks of the guide grid: the palette, per-platform
//  metrics, the programme block with its focus card, and the "now" line. The
//  same views draw the 10-foot guide and the touch/pointer one; only the
//  metrics differ.
//

import SwiftUI

// MARK: - Palette

/// Explicit guide colours. The app ships an empty `AccentColor` asset, so
/// `Color.accentColor` resolves to *white* on tvOS — which renders a focused
/// block as white text on a white fill. The guide therefore uses these
/// concrete colours and the system "focused = solid white, dark text" idiom
/// (mirroring `TVGlassButtonStyle`) instead of the accent colour.
///
/// Tiles are tinted with `.primary`, so they read on the dark tvOS backdrop
/// and on a light iOS or macOS window alike. The focus card inverts in light
/// mode: a dark card with light text.
enum EPGColors {
    /// Tint for the currently-airing programme in the player's channel list.
    static let live = Color.blue
    /// Dark text, and the light-mode card.
    static let ink = Color(.sRGB, red: 11 / 255, green: 13 / 255, blue: 18 / 255)
    static let inkSecondary = Color(.sRGB, red: 58 / 255, green: 64 / 255, blue: 76 / 255)
    /// The guide's focus card and its edge.
    static let cardFill = adaptive(light: ink, dark: .white.opacity(0.96))
    static let cardBorder = adaptive(light: .clear, dark: .white.opacity(0.6))
    /// Text on the focus card.
    static let cardText = adaptive(light: .white, dark: ink)
    static let cardTextSecondary = adaptive(light: .white.opacity(0.7), dark: inkSecondary)
    /// Text on the accent now pill.
    static let onAccent = Color(.sRGB, red: 6 / 255, green: 18 / 255, blue: 31 / 255)

    private static func adaptive(light: Color, dark: Color) -> Color {
        #if os(macOS)
            Color(NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
            })
        #else
            Color(UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
            })
        #endif
    }
}

// MARK: - Metrics

/// Platform-tuned sizing for the guide. The 10-foot UI needs far larger
/// targets and type than a phone or a pointer-driven window.
struct EPGMetrics {
    var pointsPerMinute: CGFloat
    var rowHeight: CGFloat
    var rowSpacing: CGFloat
    var channelColumnWidth: CGFloat
    var headerHeight: CGFloat
    var blockCornerRadius: CGFloat
    var blockInset: CGFloat
    /// Horizontal gap between adjacent programmes, taken from the end of
    /// each block's exact width so tiling stays aligned across rows.
    var blockGap: CGFloat
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
    var cardShadowRadius: CGFloat
    var cardShadowOpacity: Double
    var progressBarHeight: CGFloat
    var channelCornerRadius: CGFloat
    var channelCellSpacing: CGFloat
    var channelCellPadding: CGFloat
    var channelNameLineLimit: Int
    var logoSide: CGFloat
    var blockTitleFont: Font
    var cardTitleFont: Font
    var blockTimeFont: Font
    var channelNameFont: Font
    var catchupGlyphFont: Font
    var rulerFont: Font
    var nowPillFont: Font
    var cornerFont: Font

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
                blockGap: 8,
                nowLeadInMinutes: 10,
                channelColumnGap: channelColumnGap,
                focusedBlockHeight: 80,
                cardShadowRadius: 22,
                cardShadowOpacity: 0.55,
                progressBarHeight: 4,
                channelCornerRadius: 18,
                channelCellSpacing: 14,
                channelCellPadding: 16,
                channelNameLineLimit: 1,
                logoSide: 46,
                blockTitleFont: .system(size: 23, weight: .medium),
                cardTitleFont: .system(size: 24, weight: .semibold),
                blockTimeFont: .system(size: 19),
                channelNameFont: .system(size: 23, weight: .semibold),
                catchupGlyphFont: .system(size: 18, weight: .semibold),
                rulerFont: .system(size: 20),
                nowPillFont: .system(size: 18, weight: .bold),
                cornerFont: .system(size: 19)
            )
        #elseif os(macOS)
            EPGMetrics(
                pointsPerMinute: 3.4,
                rowHeight: 58,
                rowSpacing: 4,
                channelColumnWidth: 210,
                headerHeight: 32,
                blockCornerRadius: 8,
                blockInset: 10,
                blockGap: 4,
                nowLeadInMinutes: 10,
                channelColumnGap: 6,
                focusedBlockHeight: 58,
                cardShadowRadius: 6,
                cardShadowOpacity: 0.25,
                progressBarHeight: 3,
                channelCornerRadius: 10,
                channelCellSpacing: 10,
                channelCellPadding: 10,
                channelNameLineLimit: 2,
                logoSide: 34,
                blockTitleFont: .subheadline.weight(.medium),
                cardTitleFont: .subheadline.weight(.semibold),
                blockTimeFont: .caption,
                channelNameFont: .subheadline.weight(.semibold),
                catchupGlyphFont: .caption.weight(.semibold),
                rulerFont: .caption,
                nowPillFont: .caption.weight(.bold),
                cornerFont: .caption
            )
        #else
            EPGMetrics(
                pointsPerMinute: 3.0,
                rowHeight: 64,
                rowSpacing: 4,
                channelColumnWidth: 136,
                headerHeight: 32,
                blockCornerRadius: 10,
                blockInset: 10,
                blockGap: 4,
                nowLeadInMinutes: 10,
                channelColumnGap: 4,
                focusedBlockHeight: 64,
                cardShadowRadius: 6,
                cardShadowOpacity: 0.25,
                progressBarHeight: 3,
                channelCornerRadius: 12,
                channelCellSpacing: 8,
                channelCellPadding: 8,
                channelNameLineLimit: 2,
                logoSide: 36,
                blockTitleFont: .subheadline.weight(.medium),
                cardTitleFont: .subheadline.weight(.semibold),
                blockTimeFont: .caption2,
                channelNameFont: .footnote.weight(.semibold),
                catchupGlyphFont: .caption2.weight(.semibold),
                rulerFont: .caption,
                nowPillFont: .caption2.weight(.bold),
                cornerFont: .caption
            )
        #endif
    }

    /// How far a focused programme card overflows its row at the top and at
    /// the bottom. The rows and the channel column are padded by it so the
    /// first and last row's card is not clipped by the scroll view.
    var focusOverflow: CGFloat {
        (focusedBlockHeight - rowHeight) / 2
    }

    var rowStride: CGFloat {
        rowHeight + rowSpacing
    }

    /// The rows' total height, including the focus overflow padding.
    func contentHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return CGFloat(rowCount) * rowStride - rowSpacing + 2 * focusOverflow
    }

    /// The top of the row at `index` in the rows' content.
    func rowOriginY(_ index: Int) -> CGFloat {
        focusOverflow + CGFloat(index) * rowStride
    }

    /// The inverse of `rowOriginY(_:)`, rounded by `rule`.
    func rowIndex(atY offsetY: CGFloat, _ rule: FloatingPointRoundingRule) -> Int {
        guard rowStride > 0 else { return 0 }
        return Int(((offsetY - focusOverflow) / rowStride).rounded(rule))
    }
}

// MARK: - Programme block

/// A programme in the guide. Unfocused it is a translucent tile the height of
/// its row; focused (or pressed) it is the card, with inverted text and a
/// progress bar while live. On tvOS the card is taller than the row and is
/// drawn over the grid by `EPGRows`.
struct EPGProgramBlock: View {
    let cell: EPGProgramCell
    let metrics: EPGMetrics
    let now: Date
    var isFocused = false
    var canReplay = false
    /// Off outside a scroll view — a context-menu preview — where there is
    /// no scrolled edge to stick to.
    var sticksToLeadingEdge = true

    private var isLive: Bool {
        cell.isLive(at: now)
    }

    private var isCard: Bool {
        isFocused && !cell.isGap
    }

    /// Only a card that overflows its row grows its radius and inset with it;
    /// where it doesn't, a press must not nudge the text.
    private var grows: Bool {
        isFocused && metrics.focusOverflow > 0
    }

    private var height: CGFloat {
        isFocused ? metrics.focusedBlockHeight : metrics.rowHeight
    }

    private var cornerRadius: CGFloat {
        grows ? metrics.blockCornerRadius + 2 : metrics.blockCornerRadius
    }

    private var inset: CGFloat {
        grows ? metrics.blockInset + 2 : metrics.blockInset
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        labels
            .frame(width: max(0, cell.width - metrics.blockGap), height: height, alignment: .leading)
            .background(fill, in: shape)
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: isFocused ? 1.5 : 1)
            }
            .overlay(alignment: .bottom) {
                if isCard, isLive {
                    progressBar
                }
            }
            .clipShape(shape)
            .modifier(CardShadow(radius: isCard ? metrics.cardShadowRadius : 0, opacity: metrics.cardShadowOpacity))
            .opacity(opacity)
            .frame(width: cell.width, height: height, alignment: .leading)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .font(isCard ? metrics.cardTitleFont : metrics.blockTitleFont)
                .foregroundStyle(isCard ? EPGColors.cardText : .primary)
                .lineLimit(1)

            if showsTime {
                HStack(spacing: 6) {
                    if canReplay {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    Text(cell.start ..< cell.end, format: .interval.hour().minute())
                }
                .font(metrics.blockTimeFont)
                .foregroundStyle(isCard ? EPGColors.cardTextSecondary : .primary.opacity(0.6))
                .lineLimit(1)
            }
        }
        .padding(.horizontal, inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Keeps the text of a partially scrolled block readable; see
        // `EPGStickyText` for why this is a `visualEffect`.
        .visualEffect { [inset, sticksToLeadingEdge] content, proxy in
            content.offset(
                x: !sticksToLeadingEdge ? 0 : EPGStickyText.shift(
                    blockMinX: proxy.frame(in: .scrollView).minX,
                    blockWidth: proxy.size.width,
                    inset: inset
                )
            )
        }
    }

    private var title: Text {
        cell.isGap ? Text("No Programme") : Text(cell.title)
    }

    private var showsTime: Bool {
        !cell.isGap && cell.width > metrics.channelColumnWidth * 0.55
    }

    private var fill: Color {
        if isCard {
            return EPGColors.cardFill
        }
        // A focused gap keeps a light fill: a no-EPG row is one gap
        // spanning the whole track, and a solid card bar reads as noise.
        if isFocused {
            return .primary.opacity(0.18)
        }
        return .primary.opacity(isLive ? 0.12 : 0.05)
    }

    private var borderColor: Color {
        isCard ? EPGColors.cardBorder : .primary.opacity(0.1)
    }

    private var opacity: Double {
        if cell.isGap {
            return isFocused ? 1 : 0.5
        }
        guard !isFocused, cell.isPast(at: now) else { return 1 }
        return canReplay ? 0.8 : 0.55
    }

    /// Only the card casts one: a zero-radius shadow still sits in the render
    /// tree of every realized block (#27).
    private struct CardShadow: ViewModifier {
        let radius: CGFloat
        let opacity: Double

        func body(content: Content) -> some View {
            if radius > 0 {
                content.shadow(color: .black.opacity(opacity), radius: radius, y: radius)
            } else {
                content
            }
        }
    }

    private var progressBar: some View {
        EPGProgressBar(
            progress: cell.progress(at: now),
            track: EPGColors.cardText.opacity(0.14),
            fill: EPGColors.cardText,
            height: metrics.progressBarHeight
        )
        .padding(.horizontal, inset)
        .padding(.bottom, metrics.progressBarHeight * 2.25)
    }
}

#if !os(tvOS)
    /// Draws a programme button as its block: the card while pressed or under
    /// keyboard focus, the tile otherwise. Focus is only observable from
    /// inside a style.
    struct EPGProgramButtonStyle: ButtonStyle {
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
                let highlighted = isFocused || isPressed
                EPGProgramBlock(cell: cell, metrics: metrics, now: now, isFocused: highlighted, canReplay: canReplay)
                    .animation(.easeOut(duration: 0.15), value: highlighted)
            }
        }
    }
#endif

/// A capsule track filled from the leading edge to `progress`.
struct EPGProgressBar: View {
    let progress: Double
    let track: Color
    let fill: Color
    let height: CGFloat

    var body: some View {
        Capsule()
            .fill(track)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(fill)
                    .scaleEffect(x: CGFloat(progress), y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
            .frame(height: height)
    }
}

// MARK: - Now indicator

/// The vertical "now" line drawn over the grid content; the ruler's pill
/// marks the moment above it.
struct EPGNowIndicator: View {
    let height: CGFloat

    static let width: CGFloat = 2

    var body: some View {
        Rectangle()
            .fill(LiveTVPalette.accent.opacity(0.85))
            .frame(width: Self.width, height: height)
    }
}

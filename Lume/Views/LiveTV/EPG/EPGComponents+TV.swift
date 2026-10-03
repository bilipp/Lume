//
//  EPGComponents+TV.swift
//  Lume
//
//  The tvOS guide's programme block and its focused card, plus the metrics
//  only the 10-foot layout uses. Touch and pointer platforms keep
//  `EPGProgramBlockView`.
//

import SwiftUI

extension EPGMetrics {
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

#if os(tvOS)
    extension EPGMetrics {
        /// Horizontal gap between adjacent programmes, taken from the end of
        /// each block's exact width so tiling stays aligned across rows.
        var blockGap: CGFloat {
            8
        }
    }

    /// A programme in the tvOS guide. Unfocused it is a translucent tile the
    /// height of its row; focused it is the white card drawn over the grid,
    /// taller than the row, with dark text and a progress bar while live.
    struct EPGTVProgramBlock: View {
        let cell: EPGProgramCell
        let metrics: EPGMetrics
        let now: Date
        var isFocused = false
        var canReplay = false

        private var isLive: Bool {
            cell.isLive(at: now)
        }

        private var isCard: Bool {
            isFocused && !cell.isGap
        }

        private var height: CGFloat {
            isFocused ? metrics.focusedBlockHeight : metrics.rowHeight
        }

        private var cornerRadius: CGFloat {
            isFocused ? metrics.blockCornerRadius + 2 : metrics.blockCornerRadius
        }

        private var inset: CGFloat {
            isFocused ? metrics.blockInset + 2 : metrics.blockInset
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
                .modifier(CardShadow(isOn: isCard))
                .opacity(opacity)
                .frame(width: cell.width, height: height, alignment: .leading)
        }

        private var labels: some View {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.system(size: isCard ? 24 : 23, weight: isCard ? .semibold : .medium))
                    .foregroundStyle(isCard ? EPGColors.ink : .white)
                    .lineLimit(1)

                if showsTime {
                    HStack(spacing: 6) {
                        if canReplay {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        Text(cell.start ..< cell.end, format: .interval.hour().minute())
                    }
                    .font(.system(size: 19))
                    .foregroundStyle(isCard ? EPGColors.inkSecondary : .white.opacity(0.6))
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // Keeps the text of a partially scrolled block readable; see
            // `EPGStickyText` for why this is a `visualEffect`.
            .visualEffect { [inset] content, proxy in
                content.offset(
                    x: EPGStickyText.shift(
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
            if isCard { return EPGColors.cardFill }
            // A focused gap keeps a light fill: a no-EPG row is one gap
            // spanning the whole track, and a solid white bar reads as noise.
            if isFocused { return .white.opacity(0.18) }
            return .white.opacity(isLive ? 0.12 : 0.05)
        }

        private var borderColor: Color {
            isFocused ? EPGColors.cardBorder : .white.opacity(0.1)
        }

        private var opacity: Double {
            if cell.isGap { return isFocused ? 1 : 0.5 }
            guard !isFocused, cell.isPast(at: now) else { return 1 }
            return canReplay ? 0.8 : 0.55
        }

        /// Only the focused card casts one: a zero-radius shadow still sits in
        /// the render tree of every realized block (#27).
        private struct CardShadow: ViewModifier {
            let isOn: Bool

            func body(content: Content) -> some View {
                if isOn {
                    content.shadow(color: .black.opacity(0.55), radius: 22, y: 22)
                } else {
                    content
                }
            }
        }

        private var progressBar: some View {
            EPGTVProgressBar(
                progress: cell.progress(at: now),
                track: EPGColors.ink.opacity(0.14),
                fill: EPGColors.ink,
                height: 4
            )
            .padding(.horizontal, inset)
            .padding(.bottom, 9)
        }
    }

    /// A capsule track filled from the leading edge to `progress`.
    struct EPGTVProgressBar: View {
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
#endif

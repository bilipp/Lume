//
//  StreamInfoChipRow.swift
//  Lume
//
//  The Advanced stream-info readout as a wrapping row of glass chips, shared by
//  the tvOS overlay and the iOS / iPadOS / macOS / visionOS caption.
//
//  It is its own leaf because it is the only part of the player chrome that
//  changes once a second: the bitrate and the audio format are pulled from the
//  engine here (`PlayerStreamSampling`) instead of being published, so the
//  overlay, its menus and the engine view never re-render for them. The loop
//  lives only while the row is mounted, which is only while the controls show.
//

import SwiftUI

struct StreamInfoChipRow: View {
    let snapshot: PlayerInfoSnapshot
    let sampler: (any PlayerStreamSampling)?
    var alignment: HorizontalAlignment = .leading

    @State private var sample: PlayerStreamSample?

    var body: some View {
        let chips = snapshot.techChips(sample: sample)
        Group {
            if chips.isEmpty {
                // Not `EmptyView`: `.task` never fires on one, so sampling would
                // never start and the audio/bitrate chips could never appear.
                Color.clear.frame(width: 0, height: 0)
            } else {
                StreamInfoChipFlow(alignment: alignment, spacing: Self.spacing) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        StreamInfoChip(text: chip)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(snapshot.spokenTechParts(sample: sample).joined(separator: ", "))
            }
        }
        .task(id: sampler.map { ObjectIdentifier($0) }) {
            await runSampling()
        }
    }

    /// Reads the engine about once a second. The bitrate is smoothed so the
    /// chip drifts rather than jumps between segment downloads, and the state
    /// is written only when what the chips show changes.
    private func runSampling() async {
        guard let sampler else {
            sample = nil
            return
        }
        var smoothed: Double?
        while !Task.isCancelled {
            if var reading = sampler.streamSample() {
                if let bits = reading.bitsPerSecond, bits > 0 {
                    smoothed = smoothed.map { $0 + Self.smoothing * (bits - $0) } ?? bits
                } else {
                    smoothed = nil
                }
                reading.bitsPerSecond = smoothed
                if Self.displayed(reading) != Self.displayed(sample) {
                    sample = reading
                }
            } else if sample != nil {
                sample = nil
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func displayed(_ sample: PlayerStreamSample?) -> [String?] {
        [sample?.audio?.label, PlayerBitrateText.text(bitsPerSecond: sample?.bitsPerSecond)]
    }

    /// Weight of the newest reading in the bitrate average.
    private static let smoothing = 0.35

    #if os(tvOS)
        private static let spacing: CGFloat = 10
    #else
        private static let spacing: CGFloat = 6
    #endif
}

/// One glass capsule with a short label.
private struct StreamInfoChip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Self.font)
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .glassEffectCompat(.regular, in: Capsule())
    }

    #if os(tvOS)
        private static let font = Font.system(size: 22, weight: .semibold)
        private static let horizontalPadding: CGFloat = 14
        private static let verticalPadding: CGFloat = 6
    #else
        private static let font = Font.caption.weight(.semibold)
        private static let horizontalPadding: CGFloat = 8
        private static let verticalPadding: CGFloat = 3
    #endif
}

/// Lays chips out left to right and wraps onto a new line when the next one
/// doesn't fit, so a narrow iPhone in portrait keeps every chip readable
/// instead of shrinking or truncating them.
struct StreamInfoChipFlow: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = rows(for: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var originY = bounds.minY
        for row in rows(for: subviews, maxWidth: bounds.width) {
            var originX = switch alignment {
            case .trailing: bounds.maxX - row.width
            case .center: bounds.midX - row.width / 2
            default: bounds.minX
            }
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: originX, y: originY + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                originX += size.width + spacing
            }
            originY += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, added > maxWidth {
                rows.append(current)
                current = Row()
                current.width = size.width
            } else {
                current.width = added
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

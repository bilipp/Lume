//
//  EPGFrozenPanes.swift
//  Lume
//
//  The guide's frozen edges: the time ruler across the top and the channel
//  column on the left. Both mirror the grid's scroll position via the shared
//  sync; the column's cells realize only inside the quantized row window. On
//  tvOS the column is part of the guide's virtual navigation space — its
//  highlight is driven by the scroller, not by real focus.
//

import SwiftData
import SwiftUI

// MARK: - Ruler strip

/// The time ruler, shifted to mirror the grid's horizontal position. Observes
/// the shared sync's `mirror` only, so its content is built once.
struct EPGRulerStrip: View {
    let timeline: EPGTimeline
    let metrics: EPGMetrics
    let now: Date
    let sync: EPGScrollSync

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: metrics.headerHeight)
            .overlay(alignment: .leading) {
                ZStack(alignment: .topLeading) {
                    EPGTimeRuler(timeline: timeline, metrics: metrics)
                    nowPill.offset(x: timeline.x(for: now))
                }
                .frame(width: timeline.totalWidth, alignment: .leading)
                .offset(x: -sync.mirror.x)
            }
            .clipped()
    }

    private var nowPill: some View {
        Text("Now")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red))
            .fixedSize()
            .alignmentGuide(.leading) { $0.width / 2 }
    }
}

// MARK: - Frozen column

/// The channel column, shifted to mirror the grid's vertical position. Built
/// once; only the mirror offset changes as the grid scrolls, and the cells
/// realize inside the quantized row window.
struct EPGFrozenColumn: View {
    let rows: [EPGChannelRow]
    let metrics: EPGMetrics
    let sync: EPGScrollSync
    /// The row the guide's virtual focus highlights in the column (tvOS).
    let focusedRowIndex: Int?
    /// Touch/pointer: tapping a channel plays it live — the same action the
    /// tvOS channel hub performs on select. Unused on tvOS, where the focus
    /// strip owns activation.
    var onSelectChannel: (EPGChannelRow) -> Void = { _ in }
    /// Seeds Multi-View from a channel's long-press menu. Unused on tvOS, for
    /// the same reason as `onSelectChannel`.
    var onStartMultiView: (EPGChannelRow) -> Void = { _ in }

    var body: some View {
        Color.clear
            .frame(width: metrics.channelColumnWidth)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) {
                // The offset lives here, on the parent that observes it, while
                // the cells are a separate child keyed off the quantized row
                // window — a per-frame mirror write shifts the child without
                // re-running its body.
                EPGColumnCells(
                    rows: rows,
                    metrics: metrics,
                    sync: sync,
                    focusedRowIndex: focusedRowIndex,
                    onSelectChannel: onSelectChannel,
                    onStartMultiView: onStartMultiView
                )
                .equatable()
                .offset(y: -sync.mirror.y)
            }
            .clipped()
        #if !os(tvOS)
            // The channel cards on tvOS already read as a separate rail, so
            // a vertical rule would only add visual weight.
            .overlay(alignment: .trailing) { Rectangle().fill(.quaternary).frame(width: 1) }
        #endif
    }
}

/// The column's channel cells, realized only inside the shared vertical row
/// window and placed at their exact offsets — a plain `VStack` over every
/// channel built one cell (and one logo load) per channel up front, which is
/// what made large categories heavy on tvOS.
///
/// `Equatable` (and wrapped in `.equatable()` by the parent) so the parent's
/// mirror-driven re-evaluations skip this body; Observation still re-runs it
/// directly whenever `rowWindow` changes.
struct EPGColumnCells: View, Equatable {
    let rows: [EPGChannelRow]
    let metrics: EPGMetrics
    /// Observed for `rowWindow` only (per-property tracking).
    let sync: EPGScrollSync
    let focusedRowIndex: Int?
    #if !os(tvOS)
        /// For the long-press menu's favourite toggle.
        @Environment(\.modelContext) private var modelContext
    #endif
    /// Deliberately outside `==` — a fresh closure identity alone must not
    /// re-run the body.
    var onSelectChannel: (EPGChannelRow) -> Void = { _ in }
    var onStartMultiView: (EPGChannelRow) -> Void = { _ in }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows.count == rhs.rows.count
            && lhs.rows.first?.id == rhs.rows.first?.id
            && lhs.rows.last?.id == rhs.rows.last?.id
            && lhs.focusedRowIndex == rhs.focusedRowIndex
    }

    private struct IndexedRow: Identifiable {
        let index: Int
        let row: EPGChannelRow
        var id: String {
            row.id
        }
    }

    private var rowStride: CGFloat {
        metrics.rowHeight + metrics.rowSpacing
    }

    private var realizedRows: [IndexedRow] {
        let window = sync.rowWindow
        guard rowStride > 0, !rows.isEmpty else { return [] }
        let first = max(0, Int((window.start / rowStride).rounded(.down)))
        let last = min(rows.count - 1, Int((window.end / rowStride).rounded(.up)))
        guard first <= last else { return [] }
        return (first ... last).map { IndexedRow(index: $0, row: rows[$0]) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(realizedRows) { entry in
                cell(for: entry)
                    .offset(y: CGFloat(entry.index) * rowStride)
            }
        }
        .frame(
            width: metrics.channelColumnWidth,
            height: max(0, CGFloat(rows.count) * rowStride - metrics.rowSpacing),
            alignment: .topLeading
        )
    }

    /// On tvOS the cell stays a plain view — the focus strip is the guide's
    /// only focusable and owns activation. Everywhere else it's a button that
    /// plays the channel live, and carries the same long-press menu as a
    /// channel row in the list. The programme blocks keep their own menu: the
    /// channel actions belong to the channel, not to what happens to be on it.
    @ViewBuilder
    private func cell(for entry: IndexedRow) -> some View {
        #if os(tvOS)
            EPGChannelCell(row: entry.row, metrics: metrics, isFocused: entry.index == focusedRowIndex)
        #else
            Button {
                onSelectChannel(entry.row)
            } label: {
                EPGChannelCell(row: entry.row, metrics: metrics, isFocused: entry.index == focusedRowIndex)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .liveChannelMenu(
                isFavorite: entry.row.stream.isFavorite,
                onToggleFavorite: { LiveChannelFavorites.toggle(entry.row.stream, in: modelContext) },
                onStartMultiView: { onStartMultiView(entry.row) }
            )
        #endif
    }
}

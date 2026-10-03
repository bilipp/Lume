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
        #if os(tvOS)
            // Only the labels near the visible window, each placed relative to
            // the mirror: offsetting a ruler as wide as the whole day (tens of
            // thousands of points) left its animated moves uncommitted until
            // the next one, so it trailed the grid by a step.
            EPGTVTimeRuler(timeline: timeline, metrics: metrics, sync: sync)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: metrics.headerHeight)
                .clipped()
        #else
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
        #endif
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
    /// The guide's virtual focus, which highlights its row's channel (tvOS).
    let virtualFocus: EPGVirtualFocus?
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
                    virtualFocus: virtualFocus,
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
    let virtualFocus: EPGVirtualFocus?
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
            && lhs.virtualFocus == rhs.virtualFocus
    }

    private struct IndexedRow: Identifiable {
        let index: Int
        let row: EPGChannelRow
        var id: String {
            row.id
        }
    }

    private var realizedRows: [IndexedRow] {
        let window = sync.rowWindow
        guard !rows.isEmpty else { return [] }
        let first = max(0, metrics.rowIndex(atY: window.start, .down))
        let last = min(rows.count - 1, metrics.rowIndex(atY: window.end, .up))
        guard first <= last else { return [] }
        return (first ... last).map { IndexedRow(index: $0, row: rows[$0]) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(realizedRows) { entry in
                cell(for: entry)
                    .offset(y: metrics.rowOriginY(entry.index))
            }
        }
        .frame(
            width: metrics.channelColumnWidth,
            height: metrics.contentHeight(rowCount: rows.count),
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
            EPGTVChannelCell(row: entry.row, metrics: metrics, highlight: highlight(forRow: entry.index))
        #else
            Button {
                onSelectChannel(entry.row)
            } label: {
                EPGChannelCell(row: entry.row, metrics: metrics)
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

    #if os(tvOS)
        private func highlight(forRow index: Int) -> EPGChannelCellHighlight {
            switch virtualFocus {
            case let .channel(rowIndex) where rowIndex == index: .hub
            case let .cell(rowIndex, _) where rowIndex == index: .row
            default: .none
            }
        }
    #endif
}

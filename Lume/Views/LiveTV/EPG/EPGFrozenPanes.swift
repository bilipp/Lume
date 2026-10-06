//
//  EPGFrozenPanes.swift
//  Lume
//
//  The guide's frozen channel column on the left, mirroring the grid's
//  vertical scroll position via the shared sync; its cells realize only
//  inside the quantized row window. On tvOS the column is part of the guide's
//  virtual navigation space — its highlight is driven by the scroller, not by
//  real focus. The ruler across the top is `EPGRulerStrip`.
//

import SwiftData
import SwiftUI

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
            EPGChannelCell(row: entry.row, metrics: metrics, highlight: highlight(forRow: entry.index))
        #else
            Button {
                onSelectChannel(entry.row)
            } label: {
                Color.clear.frame(width: metrics.channelColumnWidth, height: metrics.rowHeight)
            }
            .buttonStyle(EPGChannelButtonStyle(row: entry.row, metrics: metrics))
            .accessibilityLabel(Text(entry.row.name))
            .liveChannelMenu(
                stream: entry.row.stream,
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

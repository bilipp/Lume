//
//  EPGProgramRows.swift
//  Lume
//
//  The programme rows inside the guide's scrollable surface: windowed
//  absolute placement of rows and cells, plus the "now" line. On tvOS cells
//  are plain views highlighted by the scroller's virtual focus; on touch and
//  pointer platforms they are tappable buttons.
//

import SwiftUI

/// The programme rows plus the now line. Rows realize only inside the shared
/// vertical row window and sit at their exact offsets; realization changes on
/// block crossings, not per scrolled frame.
///
/// `Equatable` (wrapped in `.equatable()` by the grid) so parent updates skip
/// this subtree unless the data or the virtual focus changed; Observation
/// still re-runs the body directly on row-window block crossings.
struct EPGRows: View, Equatable {
    let rows: [EPGChannelRow]
    let timeline: EPGTimeline
    let metrics: EPGMetrics
    let now: Date
    /// Observed for `rowWindow` only (per-property tracking).
    let sync: EPGScrollSync
    let dataVersion: Int
    let virtualFocus: EPGVirtualFocus?
    let onPlay: (EPGChannelRow, EPGProgramCell) -> Void
    let onShowDetails: (EPGChannelRow, EPGProgramCell) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dataVersion == rhs.dataVersion
            && lhs.rows.count == rhs.rows.count
            && lhs.virtualFocus == rhs.virtualFocus
            && lhs.timeline == rhs.timeline
    }

    private struct IndexedRow: Identifiable {
        let index: Int
        let row: EPGChannelRow
        var id: String {
            row.id
        }
    }

    private var contentHeight: CGFloat {
        metrics.contentHeight(rowCount: rows.count)
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
                EPGProgramStrip(
                    row: entry.row,
                    timeline: timeline,
                    metrics: metrics,
                    now: now,
                    sync: sync,
                    onPlay: { cell in onPlay(entry.row, cell) },
                    onShowDetails: { cell in onShowDetails(entry.row, cell) }
                )
                .equatable()
                .offset(y: metrics.rowOriginY(entry.index))
            }
        }
        .frame(width: timeline.totalWidth, height: contentHeight, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            TimelineView(.everyMinute) { context in
                EPGNowIndicator(height: contentHeight)
                    .offset(x: timeline.x(for: context.date) - 4.5)
                    .allowsHitTesting(false)
            }
        }
        #if os(tvOS)
        // Above the now line and every row, so the card's overflow and
        // shadow cover its neighbours; the strips themselves never re-render
        // for a focus move.
        .overlay(alignment: .topLeading) { focusedCard }
        #endif
    }

    #if os(tvOS)
        @ViewBuilder
        private var focusedCard: some View {
            if case let .cell(rowIndex, cellID) = virtualFocus, rows.indices.contains(rowIndex),
               let cell = rows[rowIndex].cells.first(where: { $0.id == cellID })
            {
                EPGTVProgramBlock(
                    cell: cell,
                    metrics: metrics,
                    now: now,
                    isFocused: true,
                    canReplay: EPGProgramStrip.canReplay(cell, in: rows[rowIndex], now: now)
                )
                .offset(x: timeline.x(for: cell.start), y: metrics.rowOriginY(rowIndex) - metrics.focusOverflow)
                .allowsHitTesting(false)
            }
        }
    #endif
}

// MARK: - Programme strip

/// A single channel's row of programme blocks. On tvOS the blocks are plain
/// views — the guide's focusable surface interprets the remote, and `EPGRows`
/// draws the focused card over them. On touch/pointer platforms each
/// block is a button: a tap plays, a long press opens the detail sheet.
///
/// Cells are placed at their exact timeline offset, and only the ones inside
/// the shared realization window (plus one neighbour on each side, so
/// navigation never dead-ends at a long programme crossing the window edge)
/// are built.
struct EPGProgramStrip: View, Equatable {
    let row: EPGChannelRow
    let timeline: EPGTimeline
    let metrics: EPGMetrics
    let now: Date
    /// Observed for `window` only (per-property tracking).
    let sync: EPGScrollSync
    let onPlay: (EPGProgramCell) -> Void
    let onShowDetails: (EPGProgramCell) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row.id == rhs.row.id
            && lhs.row.cells.count == rhs.row.cells.count
            && lhs.timeline == rhs.timeline
    }

    private var realizedCells: [EPGProgramCell] {
        let window = sync.window
        var result: [EPGProgramCell] = []
        var leading: EPGProgramCell?
        for cell in row.cells {
            let start = timeline.x(for: cell.start)
            let end = start + cell.width
            if start < window.end, end > window.start {
                result.append(cell)
            } else if end <= window.start {
                leading = cell
            } else {
                result.append(cell)
                break
            }
        }
        if let leading {
            result.insert(leading, at: 0)
        }
        return result
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(realizedCells) { cell in
                cellView(cell)
                    .offset(x: timeline.x(for: cell.start))
            }
        }
        .frame(width: timeline.totalWidth, height: metrics.rowHeight, alignment: .topLeading)
    }

    static func canReplay(_ cell: EPGProgramCell, in row: EPGChannelRow, now: Date) -> Bool {
        // Snapshot-based: cell realization runs mid-scroll, where a SwiftData
        // model read could fault to SQLite on the main thread.
        !cell.isGap && cell.isPast(at: now) && row.isReplayable(start: cell.start, now: now)
    }

    #if os(tvOS)
        private func cellView(_ cell: EPGProgramCell) -> some View {
            EPGTVProgramBlock(cell: cell, metrics: metrics, now: now, canReplay: Self.canReplay(cell, in: row, now: now))
        }
    #else
        @ViewBuilder
        private func cellView(_ cell: EPGProgramCell) -> some View {
            if cell.isGap {
                // A channel with no EPG is a single full-width gap; it stays a
                // playable target so the channel can be started from the grid.
                Button {
                    onPlay(cell)
                } label: {
                    Color.clear.frame(width: cell.width, height: metrics.rowHeight)
                }
                .buttonStyle(EPGBlockButtonStyle(cell: cell, metrics: metrics, now: now))
                .accessibilityLabel(Text(row.name))
                .accessibilityHint(Text("No programme information"))
            } else {
                Button {
                    onPlay(cell)
                } label: {
                    Color.clear.frame(width: cell.width, height: metrics.rowHeight)
                }
                .buttonStyle(EPGBlockButtonStyle(cell: cell, metrics: metrics, now: now, canReplay: Self.canReplay(cell, in: row, now: now)))
                // A long press opens the detail sheet. The gesture takes the
                // press once it recognizes, so a hold doesn't also fire the
                // button's play action.
                .onLongPressGesture(minimumDuration: 0.4) {
                    onShowDetails(cell)
                }
                .accessibilityLabel(Text(cell.title))
                .accessibilityHint(Text("\(cell.start, format: .dateTime.hour().minute()) to \(cell.end, format: .dateTime.hour().minute()) on \(row.name)"))
                .accessibilityAction(named: Text("Show Details")) { onShowDetails(cell) }
            }
        }
    #endif
}

//
//  EPGGridScroller.swift
//  Lume
//
//  The guide grid's scrollable machinery: the frozen ruler/channel panes and
//  the single 2D-scrollable programme surface. `EPGGuideView` shapes the data;
//  this file renders and navigates it.
//
//  On tvOS neither the channel column nor the programme cells are focusable.
//  A single focusable surface overlays the guide and interprets the remote
//  itself (`onMoveCommand`), and a *virtual* focus drives the highlight — the
//  channel column doubles as the navigation hub, exactly as it would with
//  real focus. The engine therefore tracks one view for the whole guide:
//  per-press responder walks and focus transactions were the dominant scroll
//  cost in device traces, and programmatic focus handoffs between multiple
//  focusables proved unreliable (the engine silently drops writes made from
//  its own callbacks, while the `@FocusState` binding still reflects them).
//  Every scroll is programmatic, so the frozen panes mirror with one animated
//  write per move instead of per-frame synchronization.
//

import SwiftData
import SwiftUI

/// Lays out the frozen panes (corner, ruler, channel column) beside the single
/// scrollable grid. Touch and pointer drag the grid directly; tvOS navigates
/// it via the focus surface.
struct EPGGridScroller: View {
    let rows: [EPGChannelRow]
    let timeline: EPGTimeline
    /// Bumped by `EPGGuideView` when the underlying cells change; the grid
    /// subtree is `Equatable`-gated on it.
    let dataVersion: Int
    let onPlay: (LiveStream) -> Void
    let onPlayCatchup: (LiveStream, EPGProgramCell) -> Void
    /// Seeds Multi-View from a channel's long-press menu in the column.
    var onStartMultiView: (LiveStream) -> Void = { _ in }
    /// tvOS: non-zero asks the guide to take real focus (a rail category was
    /// just activated); `onDidClaimFocus` resets it once claimed.
    var focusToken = 0
    var onDidClaimFocus: () -> Void = {}

    private let metrics = EPGMetrics.current
    private let now = Date()

    @State private var sync = EPGScrollSync()
    @State private var selection: EPGSelection?
    @State private var scrollRequest: EPGScrollRequest?
    #if os(tvOS)
        /// For the channel actions' favourite toggle.
        @Environment(\.modelContext) private var modelContext
        /// The channel whose actions the hub's long press raised.
        @State private var channelActions: EPGChannelRow?
        /// Whether the guide's focus strip holds real focus (driven by the
        /// UIKit strip's focus callbacks).
        @State private var surfaceFocused = false
        /// The channel or programme the surface highlights and acts on.
        @State private var virtualFocus: EPGVirtualFocus?
        /// The x a run of vertical cell moves keeps aiming at, so rows with
        /// different programme boundaries don't make focus drift sideways.
        @State private var preferredX: CGFloat?
        /// Bumped to hand real focus to the rail (Menu from the hub).
        @State private var railExitToken = 0
        /// SwiftUI-side focus binding for the strip. Written to claim focus
        /// after a rail category activation — at that moment SwiftUI owns
        /// focus (the rail button), so a focus-state write is honoured, where
        /// a raw `UIFocusSystem.requestFocusUpdate` is silently ignored.
        @FocusState private var surfaceClaimsFocus: Bool
    #endif

    var body: some View {
        VStack(spacing: 0) {
            // Header: corner + time ruler. Touch/pointer get a jump-to-now
            // button in the corner; tvOS auto-scrolls to now on appear and has
            // no use for a corner button it can't easily reach, so the corner
            // is left empty there.
            HStack(spacing: 0) {
                corner
                    .frame(width: metrics.channelColumnWidth, height: metrics.headerHeight)

                EPGRulerStrip(timeline: timeline, metrics: metrics, now: now, sync: sync)
            }
            .frame(height: metrics.headerHeight)

            #if !os(tvOS)
                Divider()
            #endif

            // Body: frozen channel column + scrollable programme grid.
            HStack(spacing: 0) {
                EPGFrozenColumn(
                    rows: rows,
                    metrics: metrics,
                    sync: sync,
                    focusedRowIndex: columnFocusRowIndex,
                    onSelectChannel: { onPlay($0.stream) },
                    onStartMultiView: { onStartMultiView($0.stream) }
                )

                grid
            }
            // On tvOS the focus strip overlays the channel column — the
            // guide's leftmost band, directly beside the rail. Being adjacent
            // to the rail is what makes entry (right from a category) and exit
            // (left back to it) land naturally, without guessing where focus
            // came from. The focus section wrapping the whole body wins the
            // directional entry contest against the rail's mode switch.
            #if os(tvOS)
            .overlay(alignment: .leading) { focusSurface }
            .focusSection()
            #endif
        }
        #if os(tvOS)
        .onChange(of: surfaceFocused) { _, focused in
            if focused {
                // Entering the guide lands on a channel — the hub. When the
                // virtual focus survived (details sheet round-trip), the
                // user's place is kept instead.
                guard virtualFocus == nil else { return }
                Task { @MainActor in
                    landOnChannel()
                }
            } else if selection == nil {
                // Focus left towards the rail or the tab bar. A presented
                // details sheet also steals real focus, but the user returns
                // to the guide — keep their place for that round-trip.
                virtualFocus = nil
                preferredX = nil
            }
        }
        #else
        .background(.background)
        #endif
        .sheet(item: $selection) { selection in
            EPGProgramDetailView(
                stream: selection.stream,
                cell: selection.cell,
                now: now,
                onPlay: { onPlay(selection.stream) },
                onPlayCatchup: { onPlayCatchup(selection.stream, selection.cell) }
            )
        }
    }

    private var grid: some View {
        EPGGrid(
            rows: rows,
            timeline: timeline,
            metrics: metrics,
            now: now,
            sync: sync,
            dataVersion: dataVersion,
            nowTarget: nowScrollTarget,
            scrollRequest: scrollRequest,
            virtualFocus: gridVirtualFocus,
            onPlay: { row, cell in playCell(row, cell) },
            onShowDetails: { row, cell in
                selection = EPGSelection(id: cell.id, stream: row.stream, cell: cell)
            }
        )
        .equatable()
    }

    private var gridVirtualFocus: EPGVirtualFocus? {
        #if os(tvOS)
            virtualFocus
        #else
            nil
        #endif
    }

    private var columnFocusRowIndex: Int? {
        #if os(tvOS)
            if case let .channel(rowIndex) = virtualFocus { rowIndex } else { nil }
        #else
            nil
        #endif
    }

    /// A past programme still inside the channel's archive plays as catch-up;
    /// everything else plays the channel live. Runs on selection — touching
    /// the SwiftData model here is fine.
    private func playCell(_ row: EPGChannelRow, _ cell: EPGProgramCell) {
        if !cell.isGap, cell.isPast(at: now),
           PlayableMedia.isCatchupAvailable(stream: row.stream, start: cell.start, now: now)
        {
            onPlayCatchup(row.stream, cell)
        } else {
            onPlay(row.stream)
        }
    }

    /// Scroll offset that parks `date` `metrics.nowLeadInMinutes` inside the
    /// grid's leading edge.
    private func scrollTarget(forNow date: Date) -> CGFloat {
        timeline.x(for: date.addingTimeInterval(-Double(metrics.nowLeadInMinutes) * 60))
    }

    /// The initial target, handed to the grid. Bound to the view's captured
    /// `now` on purpose: the grid's `Equatable` gate compares it, so a value
    /// that moved with the wall clock would re-render the whole subtree on
    /// every parent update. Explicit jumps read the clock instead.
    private var nowScrollTarget: CGFloat {
        scrollTarget(forNow: now)
    }

    /// Asks the grid to scroll. On tvOS the frozen panes' mirror is updated in
    /// the same breath with a matching animation, so CoreAnimation interpolates
    /// both surfaces together without per-frame main-thread work.
    private func requestScroll(to point: CGPoint, animated: Bool) {
        let clamped = CGPoint(x: max(0, point.x), y: max(0, point.y))
        scrollRequest = EPGScrollRequest(
            token: (scrollRequest?.token ?? 0) + 1,
            point: clamped,
            animated: animated
        )
        #if os(tvOS)
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    sync.mirror = clamped
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    sync.mirror = clamped
                }
            }
        #endif
    }

    @ViewBuilder
    private var corner: some View {
        #if os(tvOS)
            Color.clear
        #else
            Button {
                requestScroll(to: CGPoint(x: scrollTarget(forNow: Date()), y: sync.offset.y), animated: true)
            } label: {
                Label("Now", systemImage: "smallcircle.filled.circle")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) { Rectangle().fill(.quaternary).frame(width: 1) }
        #endif
    }
}

// MARK: - tvOS focus surface & virtual navigation

#if os(tvOS)
    extension EPGGridScroller {
        /// The guide's single focusable view — a UIKit strip over the channel
        /// column. Focus stays parked on it for the whole guide session; its
        /// `shouldUpdateFocus` veto turns the engine's movement requests
        /// (button presses *and* Siri remote swipes) into virtual navigation.
        /// Menu is handled here via `onExitCommand` — the SwiftUI layer that
        /// takes the press before an enclosing NavigationStack can pop or hop
        /// focus to the tab bar.
        private var focusSurface: some View {
            EPGFocusStrip(
                isFocused: $surfaceFocused,
                exitsLeft: exitsLeft,
                exitsUp: exitsUp,
                onMove: { direction in
                    moveVirtualFocus(direction)
                },
                onSelect: {
                    activateVirtualFocus()
                },
                onLongSelect: {
                    longSelectVirtualFocus()
                },
                railExitToken: railExitToken
            )
            .frame(width: metrics.channelColumnWidth)
            .frame(maxHeight: .infinity)
            .focused($surfaceClaimsFocus)
            .accessibilityLabel(Text(virtualFocusDescription))
            .onExitCommand {
                handleMenu()
            }
            // The channel actions a long press offers everywhere else through a
            // `contextMenu`. The guide has no focusable channel cell to hang one
            // on — a single strip owns the whole grid's focus — so the hub's
            // long press raises them itself.
            .confirmationDialog(
                channelActions?.name ?? "",
                isPresented: Binding(
                    get: { channelActions != nil },
                    set: { if !$0 { channelActions = nil } }
                ),
                titleVisibility: .visible,
                presenting: channelActions
            ) { row in
                Button(row.stream.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                    LiveChannelFavorites.toggle(row.stream, in: modelContext)
                }
                Button("Start Multi-View") {
                    onStartMultiView(row.stream)
                }
            }
            // Runs on appear *and* on token change: a category activation both
            // rebuilds the guide (fresh scroller) and bumps the token, and the
            // same-category case only bumps the token.
            .task(id: focusToken) {
                guard focusToken != 0 else { return }
                surfaceClaimsFocus = true
                onDidClaimFocus()
            }
        }

        /// Left from the channel hub leaves the guide towards the rail; from
        /// a programme it navigates back towards the column.
        private var exitsLeft: Bool {
            guard case .cell = virtualFocus else { return true }
            return false
        }

        /// Up from the top row (channel hub or cell) leaves the guide upwards
        /// to the tab bar; every deeper row moves to the row above. The strip
        /// yields the move to the engine rather than vetoing it, just like the
        /// left exit.
        private var exitsUp: Bool {
            virtualFocus?.rowIndex == 0
        }

        /// Menu steps back one level: from a programme it collapses to the
        /// channel hub; from the hub it hands focus to the category rail.
        private func handleMenu() {
            if case .cell = virtualFocus {
                handleExitCommand()
            } else {
                railExitToken += 1
            }
        }

        private var topVisibleRowIndex: Int {
            let rowStride = metrics.rowHeight + metrics.rowSpacing
            guard rowStride > 0, !rows.isEmpty else { return 0 }
            return max(0, min(rows.count - 1, Int((sync.offset.y / rowStride).rounded())))
        }

        /// Entering the guide (from the rail or the tab bar) lands on the top
        /// visible channel, reading as "now" on a channel.
        private func landOnChannel() {
            guard !rows.isEmpty else { return }
            requestScroll(to: CGPoint(x: scrollTarget(forNow: Date()), y: sync.offset.y), animated: false)
            preferredX = nil
            virtualFocus = .channel(rowIndex: topVisibleRowIndex)
        }

        private func moveVirtualFocus(_ direction: MoveCommandDirection) {
            guard let focus = virtualFocus, rows.indices.contains(focus.rowIndex) else { return }
            switch focus {
            case let .channel(rowIndex):
                moveFromChannel(rowIndex: rowIndex, direction: direction)
            case let .cell(rowIndex, cellID):
                moveFromCell(rowIndex: rowIndex, cellID: cellID, direction: direction)
            }
        }

        private func moveFromChannel(rowIndex: Int, direction: MoveCommandDirection) {
            switch direction {
            case .left:
                // Filtered by decideMove: the engine exits to the rail.
                break
            case .right:
                landVirtualFocus(onRow: rowIndex)
            case .up:
                // Row 0 exits upward to the tab bar (handled by the strip's
                // up-exit, so this never runs there); deeper rows move up one.
                if rowIndex > 0 {
                    focusChannel(rowIndex: rowIndex - 1)
                }
            case .down:
                if rowIndex + 1 < rows.count {
                    focusChannel(rowIndex: rowIndex + 1)
                }
            @unknown default:
                break
            }
        }

        private func moveFromCell(rowIndex: Int, cellID: String, direction: MoveCommandDirection) {
            let row = rows[rowIndex]
            guard let cellIndex = row.cells.firstIndex(where: { $0.id == cellID }) else { return }
            switch direction {
            case .left:
                if cellIndex > 0 {
                    preferredX = nil
                    focusCell(rowIndex: rowIndex, cell: row.cells[cellIndex - 1])
                } else {
                    focusChannel(rowIndex: rowIndex)
                }
            case .right:
                if cellIndex + 1 < row.cells.count {
                    preferredX = nil
                    focusCell(rowIndex: rowIndex, cell: row.cells[cellIndex + 1])
                }
            case .up:
                // Row 0 exits upward to the tab bar (handled by the strip's
                // up-exit, so this never runs there); deeper rows move up one.
                if rowIndex > 0 {
                    moveCellVertically(from: row.cells[cellIndex], to: rowIndex - 1)
                }
            case .down:
                if rowIndex + 1 < rows.count {
                    moveCellVertically(from: row.cells[cellIndex], to: rowIndex + 1)
                }
            @unknown default:
                break
            }
        }

        private func moveCellVertically(from cell: EPGProgramCell, to rowIndex: Int) {
            let anchorX = preferredX ?? visibleAnchorX(of: cell)
            preferredX = anchorX
            let cells = rows[rowIndex].cells
            guard let target = cells.last(where: { timeline.x(for: $0.start) <= anchorX }) ?? cells.first else { return }
            focusCell(rowIndex: rowIndex, cell: target)
        }

        /// The x a programme "reads at": the midpoint of its visible span, so
        /// vertical moves from a long programme land where the viewer looks.
        private func visibleAnchorX(of cell: EPGProgramCell) -> CGFloat {
            let start = timeline.x(for: cell.start)
            let end = start + cell.width
            let visibleStart = max(start, sync.offset.x)
            let visibleEnd = min(end, sync.offset.x + sync.viewport.width)
            guard visibleEnd > visibleStart else { return start }
            return (visibleStart + visibleEnd) / 2
        }

        /// Enters the row's programmes at the viewport's leading edge.
        private func landVirtualFocus(onRow rowIndex: Int) {
            let cells = rows[rowIndex].cells
            let leadingX = sync.offset.x + 12
            guard let cell = cells.last(where: { timeline.x(for: $0.start) <= leadingX }) ?? cells.first else { return }
            preferredX = nil
            focusCell(rowIndex: rowIndex, cell: cell)
        }

        private func focusChannel(rowIndex: Int) {
            preferredX = nil
            virtualFocus = .channel(rowIndex: rowIndex)
            ensureRowVisible(rowIndex)
        }

        private func focusCell(rowIndex: Int, cell: EPGProgramCell) {
            virtualFocus = .cell(rowIndex: rowIndex, cellID: cell.id)
            ensureCellVisible(rowIndex: rowIndex, cell: cell)
        }

        /// Scrolls just enough to keep the virtually focused programme inside
        /// the viewport, mirroring the focus engine's follow behaviour.
        private func ensureCellVisible(rowIndex: Int, cell: EPGProgramCell) {
            let viewport = sync.viewport
            guard viewport.width > 0, viewport.height > 0 else { return }
            var target = sync.offset
            let margin: CGFloat = 40
            let cellStart = timeline.x(for: cell.start)
            let cellEnd = cellStart + cell.width
            if cellStart < target.x + margin {
                target.x = cellStart - margin
            } else if cellEnd > target.x + viewport.width - margin {
                // Wide programmes pin their start to the leading edge instead
                // of pushing it off-screen.
                target.x = min(cellEnd - viewport.width + margin, cellStart - margin)
            }
            target.y = rowScrollTarget(rowIndex, currentY: target.y)
            clampAndScroll(to: target)
        }

        private func ensureRowVisible(_ rowIndex: Int) {
            guard sync.viewport.height > 0 else { return }
            var target = sync.offset
            target.y = rowScrollTarget(rowIndex, currentY: target.y)
            clampAndScroll(to: target)
        }

        private func rowScrollTarget(_ rowIndex: Int, currentY: CGFloat) -> CGFloat {
            let rowStride = metrics.rowHeight + metrics.rowSpacing
            let top = CGFloat(rowIndex) * rowStride
            let bottom = top + metrics.rowHeight
            if top < currentY {
                return top
            }
            if bottom > currentY + sync.viewport.height {
                return bottom - sync.viewport.height
            }
            return currentY
        }

        private func clampAndScroll(to point: CGPoint) {
            let rowStride = metrics.rowHeight + metrics.rowSpacing
            let contentHeight = max(0, CGFloat(rows.count) * rowStride - metrics.rowSpacing)
            var target = point
            target.x = max(0, min(target.x, max(0, timeline.totalWidth - sync.viewport.width)))
            target.y = max(0, min(target.y, max(0, contentHeight - sync.viewport.height)))
            if target != sync.offset {
                requestScroll(to: target, animated: true)
            }
        }

        /// Menu from the programmes: collapse to the channel hub and snap
        /// back to now.
        private func handleExitCommand() {
            guard case let .cell(rowIndex, _) = virtualFocus else { return }
            requestScroll(to: CGPoint(x: scrollTarget(forNow: Date()), y: sync.offset.y), animated: false)
            preferredX = nil
            virtualFocus = .channel(rowIndex: rowIndex)
        }

        private func activateVirtualFocus() {
            switch virtualFocus {
            case let .channel(rowIndex) where rows.indices.contains(rowIndex):
                onPlay(rows[rowIndex].stream)
            case let .cell(rowIndex, cellID) where rows.indices.contains(rowIndex):
                guard let cell = rows[rowIndex].cells.first(where: { $0.id == cellID }) else { return }
                playCell(rows[rowIndex], cell)
            default:
                break
            }
        }

        /// A long press means "tell me more about what's highlighted": the
        /// programme's details on a cell, the channel's own actions on the hub —
        /// which until now did nothing at all.
        private func longSelectVirtualFocus() {
            if case let .channel(rowIndex) = virtualFocus, rows.indices.contains(rowIndex) {
                channelActions = rows[rowIndex]
            } else {
                showVirtualCellDetails()
            }
        }

        private func showVirtualCellDetails() {
            guard case let .cell(rowIndex, cellID) = virtualFocus, rows.indices.contains(rowIndex),
                  let cell = rows[rowIndex].cells.first(where: { $0.id == cellID }),
                  !cell.isGap
            else { return }
            selection = EPGSelection(id: cell.id, stream: rows[rowIndex].stream, cell: cell)
        }

        private var virtualFocusDescription: String {
            guard let focus = virtualFocus, rows.indices.contains(focus.rowIndex) else { return "" }
            let row = rows[focus.rowIndex]
            guard case let .cell(_, cellID) = focus,
                  let cell = row.cells.first(where: { $0.id == cellID }), !cell.isGap
            else {
                return row.name
            }
            return "\(cell.title), \(row.name)"
        }
    }
#endif

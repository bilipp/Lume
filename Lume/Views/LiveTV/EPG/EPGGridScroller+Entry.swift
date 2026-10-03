//
//  EPGGridScroller+Entry.swift
//  Lume
//
//  Where the tvOS guide's virtual focus lands when real focus comes back.
//  Walking in from the category rail or the tab bar, or coming back from
//  full screen, lands on the hub of the channel the preview shows. A round
//  trip through something presented over the guide — the channel actions,
//  Multi-View, a programme's details — keeps the exact row and cell.
//

import SwiftUI

nonisolated enum EPGGuideEntry {
    /// The row whose channel hub an entry lands on: the previewed channel,
    /// found at its remembered index or wherever it moved since, else the top
    /// visible row. `nil` for an empty guide.
    static func landingRow<RowIDs: RandomAccessCollection<String>>(
        previewedStreamID: String?,
        previewedRowIndex: Int?,
        rowIDs: RowIDs,
        topVisibleRow: Int
    ) -> Int? where RowIDs.Index == Int {
        guard !rowIDs.isEmpty else { return nil }
        if let previewedStreamID {
            if let previewedRowIndex, rowIDs.indices.contains(previewedRowIndex),
               rowIDs[previewedRowIndex] == previewedStreamID
            {
                return previewedRowIndex
            }
            if let index = rowIDs.firstIndex(of: previewedStreamID) {
                return index
            }
        }
        return min(max(topVisibleRow, 0), rowIDs.count - 1)
    }
}

#if os(tvOS)
    extension EPGGridScroller {
        private var topVisibleRowIndex: Int {
            metrics.rowIndex(atY: sync.offset.y, .toNearestOrAwayFromZero)
        }

        /// Lands on a channel hub at now, scrolled into view in one
        /// unanimated jump.
        func landOnChannel() {
            guard let rowIndex = EPGGuideEntry.landingRow(
                previewedStreamID: previewTarget?.streamID,
                previewedRowIndex: previewTarget?.rowIndex,
                rowIDs: rows.lazy.map(\.id),
                topVisibleRow: topVisibleRowIndex
            ) else { return }
            preferredX = nil
            virtualFocus = .channel(rowIndex: rowIndex)
            var target = CGPoint(x: scrollTarget(forNow: Date()), y: sync.offset.y)
            if sync.viewport.height > 0 {
                target.y = rowScrollTarget(rowIndex, currentY: target.y)
            }
            requestScroll(to: clampedOffset(target), animated: false)
        }

        /// Anything that neither walked out nor followed Select is something
        /// presented over the guide, which keeps the exact row and cell.
        func guideDidLoseFocus(walkedOut: Bool) {
            let played = selectedBeforeDeparture
            selectedBeforeDeparture = false
            if walkedOut {
                preferredX = nil
                virtualFocus = nil
            } else if played {
                preferredX = nil
                // Coming back from full screen lands on the hub of the channel
                // that was played — even when Select beat the preview's settle,
                // so the preview still shows the channel focus started from.
                if let rowIndex = virtualFocus?.rowIndex, rows.indices.contains(rowIndex) {
                    virtualFocus = .channel(rowIndex: rowIndex)
                } else {
                    virtualFocus = nil
                }
            }
        }
    }

    extension View {
        /// Tells the Live TV screen's tab-bar entry catcher whether a guide is
        /// mounted and holds focus. A modifier, so its environment read never
        /// touches the scroller.
        func reportsGuideFocus(_ isFocused: Bool) -> some View {
            modifier(GuideFocusReport(isFocused: isFocused))
        }
    }

    private struct GuideFocusReport: ViewModifier {
        let isFocused: Bool

        @Environment(TVLiveTVFocusRegions.self) private var regions: TVLiveTVFocusRegions?

        func body(content: Content) -> some View {
            content
                .onChange(of: isFocused) { _, focused in
                    regions?.guideFocused = focused
                }
                .onAppear {
                    regions?.mountedGuides += 1
                }
                .onDisappear {
                    regions?.mountedGuides -= 1
                    if isFocused { regions?.guideFocused = false }
                }
        }
    }
#endif

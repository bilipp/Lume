//
//  EPGTimeline.swift
//  Lume
//
//  Pure layout maths for the Electronic Program Guide grid. Maps wall-clock
//  time onto horizontal points and turns a channel's listings into a fully
//  tiled row of cells (programmes plus gap fillers), so every row spans the
//  same time window and columns line up across channels.
//
//  This file has no SwiftUI dependency on purpose: the geometry is trivial to
//  reason about and cheap to compute, and keeping it out of view bodies means
//  scrolling never re-runs it.
//

import CoreGraphics
import Foundation

// MARK: - Timeline

/// A fixed window of time laid out horizontally at a constant scale.
/// `nonisolated`: cell tiling runs on a background task for large categories.
nonisolated struct EPGTimeline: Equatable {
    let start: Date
    let end: Date
    /// Horizontal points per minute. Higher = more zoomed-in.
    let pointsPerMinute: CGFloat

    var totalMinutes: CGFloat {
        CGFloat(end.timeIntervalSince(start) / 60)
    }

    var totalWidth: CGFloat {
        totalMinutes * pointsPerMinute
    }

    /// The x offset (from `start`) at which `date` sits, clamped to the window.
    func x(for date: Date) -> CGFloat {
        let clamped = min(max(date, start), end)
        return CGFloat(clamped.timeIntervalSince(start) / 60) * pointsPerMinute
    }

    /// Width of the span `from..<to` once clamped to the window.
    func width(from start: Date, to end: Date) -> CGFloat {
        max(0, x(for: end) - x(for: start))
    }

    /// Half-hour marks across the window, used to draw the time ruler.
    var halfHourTicks: [Date] {
        var result: [Date] = []
        var cursor = start
        let step: TimeInterval = 30 * 60
        while cursor <= end {
            result.append(cursor)
            cursor = cursor.addingTimeInterval(step)
        }
        return result
    }

    /// A guide window anchored around `now`: a little history for context plus a
    /// day of upcoming programmes, with the leading edge floored to a tidy
    /// half-hour so the ruler labels read cleanly.
    static func live(
        now: Date,
        pointsPerMinute: CGFloat,
        hoursBehind: Double = 1,
        hoursAhead: Double = 24,
        calendar: Calendar = .current
    ) -> EPGTimeline {
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        var floored = comps
        floored.minute = (comps.minute ?? 0) >= 30 ? 30 : 0
        floored.second = 0
        let anchor = calendar.date(from: floored) ?? now

        let start = anchor.addingTimeInterval(-hoursBehind * 3600)
        let end = start.addingTimeInterval((hoursBehind + hoursAhead) * 3600)
        return EPGTimeline(start: start, end: end, pointsPerMinute: pointsPerMinute)
    }
}

// MARK: - Sticky text

/// How far a programme block's text has to shift to stay inside the viewport.
///
/// Blocks sit at their absolute timeline offset and draw their text at their
/// own leading edge, so a programme that started before the viewport's leading
/// edge — the in-progress one the guide opens on — would render its title
/// off-screen. Shifting by the hidden amount pins the text to the visible part
/// of the block; the cap stops it from sliding out of the block's own trailing
/// edge as the block scrolls away.
///
/// `nonisolated`: called from the `visualEffect` closure, which is `@Sendable`.
nonisolated enum EPGStickyText {
    static func shift(blockMinX: CGFloat, blockWidth: CGFloat, inset: CGFloat) -> CGFloat {
        guard blockMinX < 0 else { return 0 }
        return min(-blockMinX, max(0, blockWidth - inset * 2))
    }
}

// MARK: - Grid model

/// One cell in a channel row: either a real programme or a gap filler that keeps
/// the row tiled edge-to-edge so columns stay aligned with neighbouring rows.
/// `nonisolated`: built on a background task for large categories.
nonisolated struct EPGProgramCell: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let start: Date
    let end: Date
    /// The underlying listing id, or `nil` for gap fillers.
    let listingID: String?
    let isGap: Bool
    let width: CGFloat

    func isLive(at now: Date) -> Bool {
        !isGap && start <= now && now < end
    }

    func isPast(at now: Date) -> Bool {
        end <= now
    }

    /// Fraction of the programme elapsed at `now`, in `0...1`.
    func progress(at now: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }
}

/// A single channel and its tiled programme cells for the current window.
///
/// Everything the grid renders while scrolling is snapshotted into plain
/// values at build time: SwiftData model property reads can fault to SQLite
/// on the main thread, and cell realization during a scroll does hundreds of
/// them — a source of scroll hitches on device. `stream` stays only as the
/// playback target, touched when the user selects, never while rendering.
struct EPGChannelRow: Identifiable {
    let id: String
    let stream: LiveStream
    let name: String
    let logoURL: URL?
    /// Whether the channel can serve catch-up at all (advertised archive,
    /// Xtream stream) — mirrors the `PlayableMedia.catchup` guards.
    let catchupCapable: Bool
    /// How many days the archive reaches back (≥ 1 when `catchupCapable`).
    let archiveDays: Int
    let cells: [EPGProgramCell]

    /// Snapshot equivalent of `PlayableMedia.isCatchupAvailable` for the
    /// scroll path: whether a programme starting at `start` is replayable.
    func isReplayable(start: Date, now: Date) -> Bool {
        catchupCapable && start >= now.addingTimeInterval(-TimeInterval(archiveDays) * 86400)
    }
}

// MARK: - Builder

enum EPGGridBuilder {
    /// Builds one row per stream from pre-tiled cells. The tiling itself
    /// (`cells(for:timeline:)`) runs off-main for large categories — this
    /// assembly only zips the streams with their cell arrays.
    @MainActor
    static func rows(
        streams: [LiveStream],
        cellsByChannel: [String: [EPGProgramCell]],
        timeline: EPGTimeline
    ) -> [EPGChannelRow] {
        // One shared full-window gap row for channels without guide data.
        let gapRow = cells(for: [], timeline: timeline)
        return streams.map { stream in
            let cells = stream.epgChannelId.flatMap { cellsByChannel[$0] } ?? gapRow
            return EPGChannelRow(
                id: stream.id,
                stream: stream,
                name: stream.name,
                logoURL: URL(string: stream.streamIcon ?? ""),
                catchupCapable: stream.tvArchive > 0 && stream.directURL == nil,
                archiveDays: max(1, stream.tvArchiveDuration),
                cells: cells
            )
        }
    }

    /// Anything left of a programme after overlap trimming that is shorter than
    /// this is treated as debris rather than a cell: it would render a sliver
    /// too narrow to label, and on tvOS focus could still land on it.
    private nonisolated static let minimumCellDuration: TimeInterval = 60

    /// Turns a channel's listings into contiguous cells spanning the whole
    /// window, inserting gap fillers wherever data is missing.
    ///
    /// Listings are not assumed to be sorted or disjoint. XMLTV in the wild
    /// overlaps programmes on the same channel, and cells are placed at their
    /// absolute timeline offset — so an overlap would draw two blocks on the
    /// same pixels and smear their titles together. The sweep below resolves
    /// each contested span in favour of whichever programme starts first
    /// (shortest first on a tie), trimming the loser's leading edge, so the
    /// row always comes out sorted, disjoint and edge-to-edge.
    ///
    /// `nonisolated`: runs on a background task for large categories.
    nonisolated static func cells(for listings: [EPGWindowListing], timeline: EPGTimeline) -> [EPGProgramCell] {
        var cells: [EPGProgramCell] = []
        var cursor = timeline.start

        let ordered = listings.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }

        for listing in ordered {
            let clampedEnd = min(listing.end, timeline.end)
            // Already covered by a cell that runs at least this far — the
            // cursor never moves backwards, so a contained listing is dropped
            // instead of rewinding the row into a spurious gap.
            guard clampedEnd > cursor else { continue }

            let clampedStart = max(max(listing.start, timeline.start), cursor)
            guard clampedEnd.timeIntervalSince(clampedStart) >= minimumCellDuration else { continue }

            if clampedStart > cursor {
                cells.append(gap(from: cursor, to: clampedStart, timeline: timeline))
            }

            cells.append(EPGProgramCell(
                id: listing.id,
                title: listing.title,
                detail: listing.detail,
                start: clampedStart,
                end: clampedEnd,
                listingID: listing.id,
                isGap: false,
                width: timeline.width(from: clampedStart, to: clampedEnd)
            ))
            cursor = clampedEnd
        }

        if cursor < timeline.end {
            cells.append(gap(from: cursor, to: timeline.end, timeline: timeline))
        }

        return cells
    }

    private nonisolated static func gap(from start: Date, to end: Date, timeline: EPGTimeline) -> EPGProgramCell {
        EPGProgramCell(
            id: "gap-\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)",
            title: "",
            detail: "",
            start: start,
            end: end,
            listingID: nil,
            isGap: true,
            width: timeline.width(from: start, to: end)
        )
    }
}

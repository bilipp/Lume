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
struct EPGTimeline: Equatable {
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

// MARK: - Grid model

/// One cell in a channel row: either a real programme or a gap filler that keeps
/// the row tiled edge-to-edge so columns stay aligned with neighbouring rows.
struct EPGProgramCell: Identifiable, Equatable {
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
struct EPGChannelRow: Identifiable {
    let id: String
    let stream: LiveStream
    let cells: [EPGProgramCell]

    var name: String {
        stream.name
    }

    var logoURL: URL? {
        URL(string: stream.streamIcon ?? "")
    }
}

// MARK: - Builder

enum EPGGridBuilder {
    /// Builds one row per stream, tiling each channel's listings across the
    /// window. `listingsByChannel` is expected to be grouped by `channelId` and
    /// sorted ascending by `start`.
    @MainActor
    static func rows(
        streams: [LiveStream],
        listingsByChannel: [String: [EPGListing]],
        timeline: EPGTimeline
    ) -> [EPGChannelRow] {
        streams.map { stream in
            let listings = stream.epgChannelId.flatMap { listingsByChannel[$0] } ?? []
            return EPGChannelRow(
                id: stream.id,
                stream: stream,
                cells: cells(for: listings, timeline: timeline)
            )
        }
    }

    /// Turns a channel's sorted listings into contiguous cells spanning the
    /// whole window, inserting gap fillers wherever data is missing.
    static func cells(for listings: [EPGListing], timeline: EPGTimeline) -> [EPGProgramCell] {
        var cells: [EPGProgramCell] = []
        var cursor = timeline.start

        for listing in listings {
            let clampedStart = max(listing.start, timeline.start)
            let clampedEnd = min(listing.end, timeline.end)
            guard clampedEnd > clampedStart else { continue }

            if clampedStart > cursor {
                cells.append(gap(from: cursor, to: clampedStart, timeline: timeline))
            }

            cells.append(EPGProgramCell(
                id: listing.id,
                title: listing.title,
                detail: listing.listingDescription,
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

    private static func gap(from start: Date, to end: Date, timeline: EPGTimeline) -> EPGProgramCell {
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

//
//  HueChannelLayout.swift
//  Lume
//
//  Maps an entertainment area's channels onto regions of a small downscaled
//  picture and averages each region to the colour that channel shows.
//

import Foundation

/// A downscaled frame: `width × height` pixels, row-major from the top-left,
/// three bytes (R, G, B) per pixel.
nonisolated struct HueFrameGrid: Hashable {
    static let standardWidth = 32
    static let standardHeight = 18

    let width: Int
    let height: Int
    let rgb: [UInt8]

    /// Nil unless `rgb` holds exactly `width × height × 3` bytes.
    init?(width: Int, height: Int, rgb: [UInt8]) {
        guard width > 0, height > 0, rgb.count == width * height * 3 else { return nil }
        self.width = width
        self.height = height
        self.rgb = rgb
    }

    func color(column: Int, row: Int) -> HueRGB {
        let offset = (row * width + column) * 3
        return HueRGB(
            red: Double(rgb[offset]) / 255,
            green: Double(rgb[offset + 1]) / 255,
            blue: Double(rgb[offset + 2]) / 255
        )
    }

    func average(of rect: Rect) -> HueRGB {
        var red = 0.0, green = 0.0, blue = 0.0
        for row in rect.rows {
            for column in rect.columns {
                let offset = (row * width + column) * 3
                red += Double(rgb[offset])
                green += Double(rgb[offset + 1])
                blue += Double(rgb[offset + 2])
            }
        }
        let count = Double(rect.rows.count * rect.columns.count) * 255
        guard count > 0 else { return .black }
        return HueRGB(red: red / count, green: green / count, blue: blue / count)
    }

    var full: Rect {
        Rect(columns: 0 ..< width, rows: 0 ..< height)
    }

    var meanLuma: Double {
        average(of: full).luma
    }

    nonisolated struct Rect: Hashable {
        var columns: Range<Int>
        var rows: Range<Int>
    }
}

nonisolated struct HueChannelLayout: Hashable {
    nonisolated struct Placement: Hashable {
        var channelID: UInt8
        /// Horizontal centre, `0` = left edge, `1` = right edge.
        var horizontal: Double
        /// Vertical centre, `0` = top edge, `1` = bottom edge.
        var vertical: Double
    }

    /// A row or column whose every component stays at or below this counts
    /// as a black bar. Not luma: saturated blue is dark by luma alone.
    static let barThreshold = 0.09
    /// Bars never take more than this share of either axis per side.
    static let maximumBarFraction = 0.3
    /// Each region covers this share of the picture's width and height.
    static let regionWidthFraction = 0.4
    static let regionHeightFraction = 0.5

    let placements: [Placement]

    /// Screen axes follow the area's own: `x` runs left→right and `z`
    /// bottom→top; `y` (depth) doesn't move a lamp across the picture.
    /// Channels outside the stream's `UInt8` id range are dropped.
    init(channels: [HueEntertainmentChannel]) {
        placements = channels.compactMap { channel in
            guard let id = UInt8(exactly: channel.channelID) else { return nil }
            return Placement(
                channelID: id,
                horizontal: Self.unit(channel.position.x),
                vertical: 1 - Self.unit(channel.position.z)
            )
        }
    }

    /// One colour per placement, in placement order.
    func samples(from grid: HueFrameGrid) -> [HueRGB] {
        let picture = Self.activePicture(in: grid)
        return placements.map { placement in
            grid.average(of: region(for: placement, in: picture))
        }
    }

    func region(for placement: Placement, in picture: HueFrameGrid.Rect) -> HueFrameGrid.Rect {
        HueFrameGrid.Rect(
            columns: Self.span(centre: placement.horizontal, fraction: Self.regionWidthFraction, within: picture.columns),
            rows: Self.span(centre: placement.vertical, fraction: Self.regionHeightFraction, within: picture.rows)
        )
    }

    /// The grid minus letterbox and pillarbox bars. Bars are trimmed
    /// symmetrically, so a dark sky above a bright subject isn't mistaken
    /// for a bar; an all-dark frame keeps the whole grid.
    static func activePicture(in grid: HueFrameGrid) -> HueFrameGrid.Rect {
        guard !isDark(grid, columns: grid.full.columns, rows: grid.full.rows) else { return grid.full }
        let maximumRows = Int(Double(grid.height) * maximumBarFraction)
        let maximumColumns = Int(Double(grid.width) * maximumBarFraction)

        let top = leadingBars(limit: maximumRows) { isDark(grid, columns: 0 ..< grid.width, rows: $0 ..< $0 + 1) }
        let bottom = leadingBars(limit: maximumRows) {
            isDark(grid, columns: 0 ..< grid.width, rows: grid.height - 1 - $0 ..< grid.height - $0)
        }
        let rowBars = min(top, bottom)
        let rows = rowBars ..< grid.height - rowBars

        let left = leadingBars(limit: maximumColumns) { isDark(grid, columns: $0 ..< $0 + 1, rows: rows) }
        let right = leadingBars(limit: maximumColumns) {
            isDark(grid, columns: grid.width - 1 - $0 ..< grid.width - $0, rows: rows)
        }
        let columnBars = min(left, right)
        return HueFrameGrid.Rect(columns: columnBars ..< grid.width - columnBars, rows: rows)
    }

    private static func leadingBars(limit: Int, isBar: (Int) -> Bool) -> Int {
        var count = 0
        while count < limit, isBar(count) {
            count += 1
        }
        return count
    }

    private static func isDark(_ grid: HueFrameGrid, columns: Range<Int>, rows: Range<Int>) -> Bool {
        for row in rows {
            for column in columns where grid.color(column: column, row: row).maximumComponent > barThreshold {
                return false
            }
        }
        return true
    }

    private static func span(centre: Double, fraction: Double, within range: Range<Int>) -> Range<Int> {
        let length = max(1, Int((Double(range.count) * fraction).rounded()))
        let start = Int((Double(range.lowerBound) + centre * Double(range.count) - Double(length) / 2).rounded())
        let clampedStart = min(max(start, range.lowerBound), range.upperBound - length)
        return clampedStart ..< clampedStart + length
    }

    private static func unit(_ axis: Double) -> Double {
        guard !axis.isNaN else { return 0.5 }
        return (min(max(axis, -1), 1) + 1) / 2
    }
}

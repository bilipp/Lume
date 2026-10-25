//
//  LogoBackdrop.swift
//  LumeTopShelf
//
//  Picks the tile colour a channel logo stays readable on. Only the logo's
//  edge pixels count — the ones that meet the tile. The white letters inside
//  RTL's coloured boxes never touch it, but the black "HD" beside them does,
//  so an average over every pixel chose a dark tile that swallowed the "HD".
//

import CoreGraphics
import UIKit

/// Declared in order of preference: on a near-tie the earlier case wins —
/// dark is the shelf's own look, light the cleaner fallback.
enum LogoBackdrop: CaseIterable {
    case dark
    case light
    /// For logos with both very dark and very light edges (a navy wordmark
    /// next to a white box): mid-grey keeps both readable.
    case neutral

    var color: UIColor {
        UIColor(white: whiteLevel, alpha: 1)
    }

    private var whiteLevel: CGFloat {
        switch self {
        case .dark: 0.13
        case .light: 0.9
        case .neutral: 0.55
        }
    }

    /// Below this contrast ratio against the tile, an edge pixel counts as lost.
    private static let minimumContrast = 2.0
    /// How much fewer lost pixels a later choice needs to beat an earlier one.
    private static let tieMargin = 0.02
    /// Analysis resolution: enough to keep thin wordmark strokes.
    private static let side = 48

    static func choose(for logo: CGImage) -> LogoBackdrop {
        guard let pixels = rgba(of: logo) else { return .dark }
        let edges = edgeLuminances(in: pixels)
        guard !edges.isEmpty else { return .dark }
        // The colour that loses the fewest edge pixels.
        var best = LogoBackdrop.dark
        var fewestLost = lostShare(of: edges, on: best)
        for candidate in allCases.dropFirst() {
            let lost = lostShare(of: edges, on: candidate)
            if lost < fewestLost - tieMargin {
                best = candidate
                fewestLost = lost
            }
        }
        return best
    }

    private static func lostShare(of luminances: [Double], on backdrop: LogoBackdrop) -> Double {
        let background = linear(Double(backdrop.whiteLevel))
        let lost = luminances.count { contrast($0, background) < minimumContrast }
        return Double(lost) / Double(luminances.count)
    }

    /// Relative luminance of every opaque pixel that touches a transparent
    /// one or the image border.
    private static func edgeLuminances(in pixels: [UInt8]) -> [Double] {
        func alpha(_ column: Int, _ row: Int) -> Double {
            guard (0 ..< side).contains(column), (0 ..< side).contains(row) else { return 0 }
            return Double(pixels[(row * side + column) * 4 + 3]) / 255
        }
        var result: [Double] = []
        for row in 0 ..< side {
            for column in 0 ..< side where alpha(column, row) >= 0.5 {
                let touchesBackground = [(column - 1, row), (column + 1, row), (column, row - 1), (column, row + 1)]
                    .contains { alpha($0.0, $0.1) < 0.5 }
                guard touchesBackground else { continue }
                let index = (row * side + column) * 4
                let opacity = alpha(column, row)
                // Premultiplied: divide the alpha back out.
                let channels = (0 ..< 3).map { linear(Double(pixels[index + $0]) / 255 / opacity) }
                result.append(0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2])
            }
        }
        return result
    }

    private static func rgba(of logo: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(logo, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }

    /// sRGB component to linear light.
    private static func linear(_ value: Double) -> Double {
        let value = min(max(value, 0), 1)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// WCAG contrast ratio between two relative luminances.
    private static func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}

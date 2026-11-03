//
//  HueTestPattern.swift
//  Lume
//
//  The frame source behind Settings › Philips Hue › Test Lights: every lamp
//  of the area runs through red, green, blue and white, so pairing, the
//  chosen area and the stream can be checked without playing anything. The
//  session ends like playback does, so the test also shows the restore.
//

import Foundation

nonisolated enum HueTestPattern {
    static let colors: [HueFrameGrid.LinearColor] = [
        .init(red: 1, green: 0, blue: 0),
        .init(red: 0, green: 1, blue: 0),
        .init(red: 0, green: 0, blue: 1),
        .init(red: 1, green: 1, blue: 1)
    ]

    static let stepDuration: Duration = .milliseconds(1500)

    static var duration: Duration {
        stepDuration * colors.count
    }

    /// The colour shown `elapsed` after the start; the last one holds past
    /// the end.
    static func color(at elapsed: Duration) -> HueFrameGrid.LinearColor {
        let step = max(0, Int(elapsed / stepDuration))
        return colors[min(step, colors.count - 1)]
    }

    /// One colour across the whole picture, so every channel shows it.
    static func grid(at elapsed: Duration) -> HueFrameGrid? {
        let width = HueFrameGrid.standardWidth, height = HueFrameGrid.standardHeight
        let color = color(at: elapsed)
        return HueFrameGrid(width: width, height: height, linear: Array(repeating: color, count: width * height))
    }
}

/// Starts its clock on the first frame asked for, so the bridge's setup time
/// doesn't eat into the first colour.
final class HueTestPatternSource: HueFrameSource {
    private let clock = ContinuousClock()
    private var start: ContinuousClock.Instant?

    func latestFrame() -> HueFrameSample {
        let now = clock.now
        let start = start ?? now
        self.start = start
        guard let grid = HueTestPattern.grid(at: now - start) else { return .noFrame }
        return .frame(.grid(grid))
    }

    func detach() {}
}

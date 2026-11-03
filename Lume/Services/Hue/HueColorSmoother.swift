//
//  HueColorSmoother.swift
//  Lume
//
//  Eases channel colours from frame to frame and snaps on scene cuts. Time
//  comes in with every update (seconds on any monotonic clock), so the
//  smoother never reads a clock itself.
//

import Foundation

nonisolated struct HueColorSmoother {
    nonisolated struct Configuration: Hashable {
        var timeConstant: Double
        /// A frame-luma jump above this between consecutive frames is a cut.
        var cutLumaThreshold = 0.12
        /// A mean per-component change of the channel targets above this
        /// between consecutive frames is a cut.
        var cutColorThreshold = 0.2
        /// With Reduce Motion a cut fades instead of snapping.
        var reduceMotion = false
        var reducedMotionCutTimeConstant = 0.1
        var reducedMotionCutDuration = 0.4
        /// With Reduce Motion no component moves faster than this per second.
        var reducedMotionMaximumRate = 2.5
    }

    nonisolated struct Target: Hashable {
        var channels: [HueRGB]
        var frameLuma: Double
    }

    var configuration: Configuration
    private(set) var current: [HueRGB] = []
    private var previousTarget: Target?
    private var lastTime: Double?
    private var cutFadeEnds: Double?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// The first frame, and any frame whose channel count changed, is shown
    /// as is.
    mutating func update(_ target: Target, at time: Double) -> [HueRGB] {
        defer {
            previousTarget = target
            lastTime = time
        }
        guard let previous = previousTarget, let last = lastTime, current.count == target.channels.count else {
            current = target.channels
            return current
        }
        let elapsed = max(0, time - last)

        if Self.isCut(from: previous, to: target, configuration: configuration) {
            if configuration.reduceMotion {
                cutFadeEnds = time + configuration.reducedMotionCutDuration
            } else {
                cutFadeEnds = nil
                current = target.channels
                return current
            }
        }

        var timeConstant = configuration.timeConstant
        if let fadeEnd = cutFadeEnds {
            if time < fadeEnd {
                timeConstant = min(timeConstant, configuration.reducedMotionCutTimeConstant)
            } else {
                cutFadeEnds = nil
            }
        }
        let blend = timeConstant > 0 ? 1 - exp(-elapsed / timeConstant) : 1
        let maximumStep = configuration.reduceMotion ? configuration.reducedMotionMaximumRate * elapsed : .infinity

        current = zip(current, target.channels).map { eased, goal in
            HueRGB(
                red: Self.step(eased.red, goal.red, blend: blend, limit: maximumStep),
                green: Self.step(eased.green, goal.green, blend: blend, limit: maximumStep),
                blue: Self.step(eased.blue, goal.blue, blend: blend, limit: maximumStep)
            )
        }
        return current
    }

    static func isCut(from previous: Target, to next: Target, configuration: Configuration) -> Bool {
        if abs(next.frameLuma - previous.frameLuma) > configuration.cutLumaThreshold {
            return true
        }
        guard previous.channels.count == next.channels.count, !next.channels.isEmpty else { return false }
        let total = zip(previous.channels, next.channels).reduce(0.0) { sum, pair in
            sum + abs(pair.0.red - pair.1.red) + abs(pair.0.green - pair.1.green) + abs(pair.0.blue - pair.1.blue)
        }
        return total / Double(next.channels.count * 3) > configuration.cutColorThreshold
    }

    private static func step(_ from: Double, _ target: Double, blend: Double, limit: Double) -> Double {
        let delta = (target - from) * blend
        return from + min(max(delta, -limit), limit)
    }
}

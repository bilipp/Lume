//
//  HueFrameSampler.swift
//  Lume
//
//  Turns the frames a `HueFrameSource` hands out into stream packets, one per
//  tick, off the main actor: downscale → channel regions → smoothing →
//  intensity → HueStream encoding.
//

import CoreVideo
import Foundation

/// The sampling steps without a queue of their own. Not thread-safe.
nonisolated struct HueFramePipeline {
    let layout: HueChannelLayout
    private(set) var intensity: HueIntensity
    private var message: HueStreamMessage
    private var smoother: HueColorSmoother
    private let downscaler: HueFrameDownscaler
    /// The last colours sent, before intensity: held while no new frame
    /// arrives, and re-shaped when the intensity changes.
    private var lastSmoothed: [HueRGB] = []
    /// Held so a source handing back its cached frame on the next tick isn't
    /// downscaled again; holding it also keeps the pool from recycling it
    /// under the identity check.
    private var lastBuffer: CVPixelBuffer?
    private var lastTarget: HueColorSmoother.Target?

    /// Nil when the id isn't a stream-ready configuration id or the area has
    /// more channels than one packet carries.
    init?(
        entertainmentConfigurationID: String,
        layout: HueChannelLayout,
        intensity: HueIntensity,
        reduceMotion: Bool,
        downscaler: HueFrameDownscaler = HueFrameDownscaler()
    ) {
        guard let message = HueStreamMessage(
            entertainmentConfigurationID: entertainmentConfigurationID,
            channels: layout.placements.map { .normalized(id: $0.channelID, red: 0, green: 0, blue: 0) }
        ) else { return nil }
        self.message = message
        self.layout = layout
        self.intensity = intensity
        self.downscaler = downscaler
        smoother = HueColorSmoother(configuration: .init(
            timeConstant: intensity.parameters?.smoothingTimeConstant ?? 0,
            reduceMotion: reduceMotion
        ))
    }

    mutating func setIntensity(_ newValue: HueIntensity) {
        intensity = newValue
        if let parameters = newValue.parameters {
            smoother.configuration.timeConstant = parameters.smoothingTimeConstant
        }
    }

    mutating func setReduceMotion(_ newValue: Bool) {
        smoother.configuration.reduceMotion = newValue
    }

    /// `time` is seconds on a monotonic clock. A missing or unavailable frame
    /// repeats the last colours, which also keeps the bridge's stream alive;
    /// nil before the first frame and while the intensity is off.
    mutating func packet(for sample: HueFrameSample, at time: Double) -> Data? {
        guard let parameters = intensity.parameters else { return nil }
        if case let .frame(frame) = sample {
            if case let .pixelBuffer(buffer) = frame, buffer === lastBuffer, let lastTarget {
                lastSmoothed = smoother.update(lastTarget, at: time)
            } else if let grid = grid(from: frame) {
                let mapping = Perf.begin(.hueMap)
                let target = HueColorSmoother.Target(
                    channels: layout.samples(from: grid),
                    frameLuma: grid.meanLuma
                )
                lastTarget = target
                lastSmoothed = smoother.update(target, at: time)
                Perf.end(mapping)
            } else {
                lastTarget = nil
            }
        }
        guard lastSmoothed.count == layout.placements.count, !lastSmoothed.isEmpty else { return nil }
        return Perf.measure(.hueEncode) {
            message.channels = zip(layout.placements, lastSmoothed).map { placement, color in
                parameters.apply(to: color).channel(id: placement.channelID)
            }
            let data = message.encoded()
            message.sequence &+= 1
            return data
        }
    }

    private mutating func grid(from frame: HueFrame) -> HueFrameGrid? {
        switch frame {
        case let .grid(grid):
            lastBuffer = nil
            return grid
        case let .pixelBuffer(buffer):
            lastBuffer = buffer
            return Perf.measure(.hueDownscale) { downscaler.grid(from: buffer) }
        }
    }
}

/// Owns one `HueFramePipeline` on a serial queue of its own. Every call
/// returns at once; a pixel buffer is held until the next one replaces it.
final nonisolated class HueFrameSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bilipp.Lume.hue.sampler", qos: .userInteractive)
    /// Only touched on `queue`.
    private var pipeline: HueFramePipeline

    init?(
        entertainmentConfigurationID: String,
        layout: HueChannelLayout,
        intensity: HueIntensity,
        reduceMotion: Bool
    ) {
        guard let pipeline = HueFramePipeline(
            entertainmentConfigurationID: entertainmentConfigurationID,
            layout: layout,
            intensity: intensity,
            reduceMotion: reduceMotion
        ) else { return nil }
        self.pipeline = pipeline
    }

    /// `deliver` runs on the sampler's queue, and only when there is a packet.
    func submit(_ sample: HueFrameSample, at time: Double, deliver: @escaping @Sendable (Data) -> Void) {
        queue.async { [self] in
            if let packet = pipeline.packet(for: sample, at: time) {
                deliver(packet)
            }
        }
    }

    func setIntensity(_ intensity: HueIntensity) {
        queue.async { [self] in pipeline.setIntensity(intensity) }
    }

    func setReduceMotion(_ reduceMotion: Bool) {
        queue.async { [self] in pipeline.setReduceMotion(reduceMotion) }
    }
}

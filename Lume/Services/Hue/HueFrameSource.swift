//
//  HueFrameSource.swift
//  Lume
//
//  The seam between a playback engine and Hue light sync: each supported
//  engine hands out the frame it shows, either as the decoder's pixel buffer
//  or as a grid the engine already downscaled, and both feed one sampler.
//

import CoreVideo
import Foundation

nonisolated enum HueFrame: @unchecked Sendable {
    /// Read-only from here on: the engine has already drawn or queued it.
    case pixelBuffer(CVPixelBuffer)
    case grid(HueFrameGrid)
}

nonisolated enum HueFrameUnavailableReason: Hashable {
    /// The engine, or the path it took for this stream, has no frame tap.
    case unsupportedEngine
    /// The engine's frames don't hold displayable colour (Dolby Vision
    /// profile 5 decodes to IPT, not RGB or YCbCr).
    case unsupportedContent

    /// Profile 5 has no backward-compatible base layer, so a decoder that
    /// doesn't apply the RPU hands out IPT.
    static func forDolbyVisionProfile(_ profile: UInt8?) -> HueFrameUnavailableReason? {
        profile == 5 ? .unsupportedContent : nil
    }
}

nonisolated enum HueFrameSample {
    case frame(HueFrame)
    /// Nothing decoded yet, or the player is between streams: keep the
    /// colours the lamps show.
    case noFrame
    case unavailable(HueFrameUnavailableReason)
}

/// Main actor, because engines publish their current frame there. A call only
/// takes a reference to that frame; downscaling it is the caller's job, off
/// the main actor. A source holds its engine weakly and does nothing until
/// asked for a frame.
protocol HueFrameSource: AnyObject {
    /// Set when the source can never give frames, so the session reports it
    /// before the first tick.
    var unavailableReason: HueFrameUnavailableReason? { get }
    func latestFrame() -> HueFrameSample
    /// Removes any tap the source attached to the engine. Called when sync
    /// stops; a later `latestFrame()` may attach it again.
    func detach()
}

extension HueFrameSource {
    var unavailableReason: HueFrameUnavailableReason? {
        nil
    }
}

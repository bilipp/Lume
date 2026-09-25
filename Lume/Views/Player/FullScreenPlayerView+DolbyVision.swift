import OSLog
import SwiftUI

/// Content-driven engine routing for Dolby Vision profiles 5, 20 and 10.0.
///
/// Their base layer is IPT-PQ-c2, not YCbCr, and only LumeEngine applies the
/// RPU that turns it back into a real picture: KSPlayer, VLCKit and AVPlayer
/// all *start* such a stream fine and show it pink/green. The failure-driven
/// fallback chain therefore never fires, so the switch is driven by what the
/// stream is instead: an engine that can read the stream's DV configuration
/// record reports it, and the host swaps to LumeEngine for that stream,
/// resuming where it was.
///
/// Always on, no setting (decided 2026-09-25): it fires only for content every
/// other engine is known to render wrong, which is a narrow, deliberate
/// exception to "LumeEngine is never silently promoted". If LumeEngine then
/// fails to start the stream, playback returns to the user's engine — a
/// tinted picture beats none — and the stream is not routed again.
extension FullScreenPlayerView {
    /// LumeEngine is driving the active stream because of its Dolby Vision
    /// base layer rather than the user's priority list.
    var isDolbyVisionRoute: Bool {
        !isAirPlayOverride
            && priorityEngine != .lumeEngine
            && dolbyVisionIPTStreams.contains(activeMedia.id)
            && !dolbyVisionRouteFailed.contains(activeMedia.id)
    }

    /// An engine found an IPT Dolby Vision base layer on the active stream.
    func routeToLumeEngineForDolbyVision() {
        let id = activeMedia.id
        // AirPlay keeps precedence: LumeEngine cannot hand video to a receiver.
        guard !isAirPlayOverride, priorityEngine != .lumeEngine,
              !dolbyVisionIPTStreams.contains(id), !dolbyVisionRouteFailed.contains(id)
        else { return }
        let from = priorityEngine.rawValue
        Logger.player.log("dolby vision IPT base layer on \(from, privacy: .public); switching to lumeEngine")
        dolbyVisionIPTStreams.insert(id)
        resumeAfterEngineSwap()
    }

    /// LumeEngine could not start the stream. On a Dolby Vision route that
    /// means "go back to the engine the user chose", not "advance the list".
    func handleLumeEngineFailure() {
        guard isDolbyVisionRoute else {
            fallBackToNextEngine()
            return
        }
        let userEngine = priorityEngine.rawValue
        Logger.player.log("lumeEngine could not start the dolby vision stream; returning to \(userEngine, privacy: .public)")
        dolbyVisionRouteFailed.insert(activeMedia.id)
        resumeAfterEngineSwap()
    }

    /// Carries the position across the swap (VOD only), like the AirPlay path.
    private func resumeAfterEngineSwap() {
        guard !activeMedia.isLive, clock.current > 1 else { return }
        resumeActiveMedia(at: clock.current)
    }
}

/// The one rule, kept next to the routing and free of engine types so any
/// engine's DV record can be checked against it.
nonisolated enum DolbyVisionBaseLayer {
    /// Profile 5, 20 or 10.0: the base layer is IPT and needs the RPU applied.
    /// Profiles 4 / 7 can declare compatibility id 0 too, but their base layer
    /// is YCbCr with an enhancement layer, so they are excluded — mirroring
    /// LumeEngine's `TrackInfo.DolbyVision.hasIPTBaseLayer`.
    static func isIPT(profile: Int, compatibilityID: Int) -> Bool {
        compatibilityID == 0 && [5, 10, 20].contains(profile)
    }
}

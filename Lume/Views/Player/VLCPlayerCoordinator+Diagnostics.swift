//
//  VLCPlayerCoordinator+Diagnostics.swift
//  Lume
//
//  Stream-health sampling and the libvlc log bridge, split out of
//  VLCPlayerCoordinator to keep that file within the project's size limit.
//

import Foundation
import OSLog
import VLCKit

extension VLCPlayerCoordinator {
    // MARK: - State logging

    /// Log player state transitions. Buffering is no longer a discrete state in
    /// VLCKit 4 — its duration is measured separately in
    /// ``mediaPlayerBufferingChanged(_:)``, which also feeds `PlaybackQoE`.
    ///
    /// Lives here rather than beside its caller purely for file size; it is
    /// called from `mediaPlayerStateChanged(_:)` on the main queue.
    func logStateChange() {
        let state = mediaPlayer.state
        let name = VLCMediaPlayerStateToString(state)
        guard name != lastStateName else { return }
        lastStateName = name

        Logger.player.log("state → \(name, privacy: .public)")

        // Re-assert deinterlace once a vout exists: the runtime setting doesn't
        // survive the output being (re)created, e.g. across a stream reload.
        if state == .playing { applyDeinterlace() }

        if state == .error {
            Logger.player.error("player entered error state")
        }
    }

    // MARK: - Diagnostics

    private static var didInstallLogBridge = false

    static func installLibVLCLogBridgeIfNeeded() {
        guard !didInstallLogBridge else { return }
        didInstallLogBridge = true
        VLCLibrary.shared().loggers = [VLCLogBridge()]
    }

    /// Begin periodic stream-health sampling. Idempotent. Debug-only: it's
    /// purely diagnostic and otherwise runs on the main runloop every 2s
    /// throughout playback, so it's compiled out of release builds.
    func startStatsLogging() {
        lastStats = nil
        statsTimer?.invalidate()
        statsTimer = nil
        #if DEBUG
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                self?.logStreamHealth()
            }
            // Diagnostic sampling doesn't need exact firing; a tolerance lets
            // the system coalesce the wake-up with other timers.
            timer.tolerance = 0.2
            // Common mode so sampling continues during scrolling / tracking
            // runloop activity in the player UI.
            RunLoop.main.add(timer, forMode: .common)
            statsTimer = timer
        #endif
    }

    func stopStatsLogging() {
        statsTimer?.invalidate()
        statsTimer = nil
        lastStats = nil
    }

    #if DEBUG
        /// Snapshot `VLCMedia.statistics` and log it as deltas since the previous
        /// sample, so the rate of dropped/late frames and discontinuities — the
        /// signals behind live-stream stutter — is directly readable. Cumulative
        /// counters are differenced; bitrates are instantaneous.
        private func logStreamHealth() {
            guard let stats = mediaPlayer.media?.statistics else { return }
            defer { lastStats = stats }

            let position = (mediaPlayer.time.value?.doubleValue ?? 0) / 1000
            let state = VLCMediaPlayerStateToString(mediaPlayer.state)

            // Deltas over the sample window (≈2s). First sample has no baseline.
            let prev = lastStats
            let dDisplayed = stats.displayedPictures - (prev?.displayedPictures ?? stats.displayedPictures)
            let dLate = stats.latePictures - (prev?.latePictures ?? stats.latePictures)
            let dLost = stats.lostPictures - (prev?.lostPictures ?? stats.lostPictures)
            let dLostAudio = stats.lostAudioBuffers - (prev?.lostAudioBuffers ?? stats.lostAudioBuffers)
            let dDiscont = stats.demuxDiscontinuity - (prev?.demuxDiscontinuity ?? stats.demuxDiscontinuity)
            let dCorrupt = stats.demuxCorrupted - (prev?.demuxCorrupted ?? stats.demuxCorrupted)

            let inputKbps = stats.inputBitrate * 8000 // bytes/ms → kbit/s
            let demuxKbps = stats.demuxBitrate * 8000

            Logger.player.debug(
                """
                health t=\(position, format: .fixed(precision: 1), privacy: .public)s state=\(state, privacy: .public) \
                input=\(inputKbps, format: .fixed(precision: 0), privacy: .public)kbps \
                demux=\(demuxKbps, format: .fixed(precision: 0), privacy: .public)kbps \
                displayed+\(dDisplayed, privacy: .public) late+\(dLate, privacy: .public) lost+\(dLost, privacy: .public) \
                audioLost+\(dLostAudio, privacy: .public) discont+\(dDiscont, privacy: .public) corrupt+\(dCorrupt, privacy: .public)
                """
            )

            // Call out the symptoms most associated with stutter at a level that
            // survives release-log filtering.
            if dLost > 0 || dLate > 0 || dDiscont > 0 || dLostAudio > 0 {
                Logger.player.warning(
                    "stutter signals: lost=\(dLost, privacy: .public) late=\(dLate, privacy: .public) discont=\(dDiscont, privacy: .public) audioLost=\(dLostAudio, privacy: .public) over ~2s"
                )
            }
        }
    #endif
}

// MARK: - libvlc log bridge

/// Forwards libvlc's internal log messages into `Logger.player`, mapping VLC
/// log levels onto the unified-logging levels so decoder/demux failures show
/// up under the `Player` category alongside our structured samples.
private final class VLCLogBridge: NSObject, VLCLogging {
    var level: VLCLogLevel = .warning

    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        // Keychain HTTP-auth probe (errSecItemNotFound) — emitted per request,
        // harmless, and drowns out everything else. Drop it.
        if message.contains("lookup failed (-25300") { return }

        // libvlc echoes the full MRL in many messages ("open of '…' failed",
        // redirects, access setup) — and stream URLs carry the playlist
        // credentials, so scrub before the public interpolation.
        let scrubbed = LogRedaction.scrubURLs(in: message)
        let module = context?.module ?? "vlc"
        switch logLevel {
        case .error:
            Logger.player.error("libvlc[\(module, privacy: .public)] \(scrubbed, privacy: .public)")
        case .warning:
            Logger.player.warning("libvlc[\(module, privacy: .public)] \(scrubbed, privacy: .public)")
        case .info:
            Logger.player.info("libvlc[\(module, privacy: .public)] \(scrubbed, privacy: .public)")
        default:
            Logger.player.debug("libvlc[\(module, privacy: .public)] \(scrubbed, privacy: .public)")
        }
    }
}

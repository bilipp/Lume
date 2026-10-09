//
//  AVPlayerCoordinator+Volume.swift
//  Lume
//
//  The macOS player's app-level volume, and the AirPlay state that hides its
//  control. Split out of AVPlayerCoordinator to keep that file within the
//  project's size limit.
//

import AVFoundation
import Foundation

extension AVPlayerCoordinator: PlayerVolumeApplying {
    var isVolumeRoutedExternally: Bool {
        isExternalPlaybackActive
    }

    /// The `AVPlayer` outlives `replaceCurrentItem`, so one call covers every
    /// later stream in this session.
    func applyUserVolume(level: Float, muted: Bool) {
        player.volume = level
        isMuted = muted
        #if os(macOS)
            if externalPlaybackObservation == nil { observeExternalPlayback() }
        #endif
    }

    #if os(macOS)
        /// An AirPlay receiver keeps its own volume, so the control hides while
        /// one is playing. Started by the first volume push, so only sessions
        /// that show the control observe it.
        private func observeExternalPlayback() {
            externalPlaybackObservation = player.observe(
                \.isExternalPlaybackActive, options: [.initial, .new]
            ) { [weak self] player, _ in
                let active = player.isExternalPlaybackActive
                DispatchQueue.main.async { [weak self] in
                    guard let self, isExternalPlaybackActive != active else { return }
                    isExternalPlaybackActive = active
                }
            }
        }
    #endif
}

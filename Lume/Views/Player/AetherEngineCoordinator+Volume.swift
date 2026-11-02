//
//  AetherEngineCoordinator+Volume.swift
//  Lume
//
//  The player's app-level volume and mute, applied as the engine's volume.
//

#if !os(visionOS)

    import Foundation
    import LumeAetherBridge

    extension AetherEngineCoordinator: PlayerVolumeApplying {
        func applyUserVolume(level: Float, muted: Bool) {
            userVolume = level
            if isMuted == muted {
                applyAudioLevel()
            } else {
                isMuted = muted
            }
        }

        /// The engine has no mute of its own: muted is volume 0. A write before
        /// a load is remembered by the engine and applied when it starts.
        func applyAudioLevel() {
            session?.volume = isMuted ? 0 : userVolume
        }
    }

#endif

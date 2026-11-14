//
//  AetherEngineCoordinator+AudioChannels.swift
//  Lume
//
//  The channel count the playing track asks the audio session for.
//

#if !os(visionOS)

    import Foundation
    import LumeAetherBridge

    extension AetherEngineCoordinator {
        /// The engine writes this preference itself on its renderer paths, to
        /// the same value; its AVPlayer path leaves the session's as it found
        /// it, so the app sets it there. A Multiview tile or guide preview
        /// leaves the session's width alone.
        func preferAudioChannels(of track: LumeAetherTrack?) {
            guard !isEmbedded else { return }
            PlayerAudioChannelPreference.apply(sourceChannels: track?.channels)
        }
    }

#endif

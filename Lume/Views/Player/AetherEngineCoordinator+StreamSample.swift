//
//  AetherEngineCoordinator+StreamSample.swift
//  Lume
//
//  The stream-info chips' audio and bitrate reading for AetherEngine.
//

#if !os(visionOS)

    import Foundation
    import LumeAetherBridge

    extension AetherEngineCoordinator: PlayerStreamSampling {
        /// The playing audio track and the engine's measured bitrate of what
        /// it is actually playing.
        func streamSample() -> PlayerStreamSample? {
            guard let session else { return nil }
            let tracks = session.audioTracks
            let audio = (tracks.first { $0.id == session.activeAudioTrackID } ?? tracks.first)
                .map { PlayerAudioInfo(codec: $0.codec.isEmpty ? nil : $0.codec, channels: $0.channels) }
            let bits = session.playedBitrateMbps.map { $0 * 1_000_000 }
            guard audio != nil || bits != nil else { return nil }
            return PlayerStreamSample(audio: audio, bitsPerSecond: bits)
        }
    }

#endif

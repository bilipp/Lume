//
//  KSPlayerHueFrameSource+MEPlayer.swift
//  Lume
//
//  KSMEPlayer keeps the last pixel buffer its display link drew; Hue reads
//  that reference and never asks the player to render or convert anything.
//

#if os(tvOS)
    import AVFoundation
    import KSPlayer

    extension KSPlayerHueFrameSource {
        func latestFrame(of player: KSMEPlayer, url: URL) -> HueFrameSample {
            if let reason = unavailableReason(of: player, url: url) {
                return .unavailable(reason)
            }
            guard let drawn = player.videoOutput?.pixelBuffer else { return .noFrame }
            // Software-decoded frames that KSPlayer keeps as Metal planes have
            // no CVPixelBuffer; say so instead of freezing the lamps.
            guard let buffer = drawn.cvPixelBuffer else {
                return .unavailable(.unsupportedContent)
            }
            return .frame(.pixelBuffer(buffer))
        }

        /// The Dolby Vision check, kept per player and stream once the stream
        /// has tracks; its profile never changes within a stream.
        private func unavailableReason(of player: KSMEPlayer, url: URL) -> HueFrameUnavailableReason? {
            let key = StreamKey(player: ObjectIdentifier(player), url: url)
            if let cached = contentCheck, cached.key == key {
                return cached.reason
            }
            let tracks = player.tracks(mediaType: .video)
            let profile = tracks.first { $0.isEnabled }?.dovi?.dv_profile
            let reason = HueFrameUnavailableReason.forDolbyVisionProfile(profile)
            if !tracks.isEmpty {
                contentCheck = (key, reason)
            }
            return reason
        }
    }
#endif

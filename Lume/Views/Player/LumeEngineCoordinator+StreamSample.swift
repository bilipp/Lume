//
//  LumeEngineCoordinator+StreamSample.swift
//  Lume
//
//  The stream-info chips' audio and bitrate reading for LumeEngine.
//

import Foundation
import LumeEngine

extension LumeEngineCoordinator: PlayerStreamSampling {
    /// The selected audio track, and the container's bitrate from when the
    /// source opened: LumeEngine reports no running rate, so the chip shows the
    /// stream's declared one and holds still.
    func streamSample() -> PlayerStreamSample? {
        guard let info = mediaInfo else { return nil }
        let tracks = info.audioTracks
        let audio = (tracks.first { String($0.index) == selectedAudioID } ?? tracks.first).map { track in
            PlayerAudioInfo(codec: track.codecName.isEmpty ? nil : track.codecName, channels: track.audio?.channels ?? 0)
        }
        let bits = info.bitrate > 0 ? Double(info.bitrate) : nil
        guard audio != nil || bits != nil else { return nil }
        return PlayerStreamSample(audio: audio, bitsPerSecond: bits)
    }
}

//
//  VLCPlayerCoordinator+StreamSample.swift
//  Lume
//
//  The stream-info chips' audio and bitrate reading for VLCKit.
//

import Foundation
import VLCKit

extension VLCPlayerCoordinator: PlayerStreamSampling {
    /// The selected audio track's format and libVLC's demux bitrate. libVLC
    /// reports bitrates in kilobytes per millisecond; the input rate stands in
    /// while the demuxer has nothing buffered.
    func streamSample() -> PlayerStreamSample? {
        let tracks = mediaPlayer.audioTracks
        let audio = (tracks.first(where: \.isSelected) ?? tracks.first).map { track in
            PlayerAudioInfo(
                codec: PlayerCodecLabel.fourCC(track.codec) ?? PlayerCodecLabel.fourCC(track.fourcc),
                channels: Int(track.audio?.channelsNumber ?? 0)
            )
        }
        var bits: Double?
        if let stats = mediaPlayer.media?.statistics {
            let rate = stats.demuxBitrate > 0 ? stats.demuxBitrate : stats.inputBitrate
            if rate > 0 {
                bits = Double(rate) * 8_000_000
            }
        }
        guard audio != nil || bits != nil else { return nil }
        return PlayerStreamSample(audio: audio, bitsPerSecond: bits)
    }
}

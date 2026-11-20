//
//  AVPlayerCoordinator+StreamSample.swift
//  Lume
//
//  The stream-info chips' bitrate reading for AVPlayer.
//

import AVFoundation

extension AVPlayerCoordinator: PlayerStreamSampling {
    /// The bitrate of the variant playing now; AVFoundation reports no audio
    /// format worth reading off the item, so that chip stays hidden here.
    func streamSample() -> PlayerStreamSample? {
        guard let event = item?.accessLog()?.events.last else { return nil }
        let bits = event.indicatedBitrate > 0 ? event.indicatedBitrate : event.observedBitrate
        guard bits.isFinite, bits > 0 else { return nil }
        return PlayerStreamSample(audio: nil, bitsPerSecond: bits)
    }
}

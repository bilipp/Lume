//
//  KSVideoInfo.swift
//  Lume
//
//  Video-track introspection for the KSPlayer engine, shared by every platform.
//
//  KSPlayer ships on every platform, so this must stay ungated: the tvOS overlay
//  reads it through `KSTVPlaybackEngine`, the iOS / macOS / visionOS hosts read
//  it directly. One implementation so the two can never drift.
//

import AVFoundation
import CoreMedia
import KSPlayer

enum KSVideoInfo {
    /// Resolution / frame rate / codec of the layer's first video track, or
    /// `nil` while no track carries usable dimensions (the first seconds of
    /// every stream, and audio-only sources).
    static func resolve(from layer: KSPlayerLayer?) -> PlayerVideoInfo? {
        guard let track = layer?.player.tracks(mediaType: .video).first else { return nil }

        var width = 0
        var height = 0
        if let format = track.formatDescription {
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            width = Int(dims.width)
            height = Int(dims.height)
        }
        let fps = track.nominalFrameRate > 0 ? Double(track.nominalFrameRate) : 0
        guard width > 0, height > 0 else { return nil }
        let codec = codecName(for: track)
        // Not KSPlayer's own `dynamicRange`: it calls every 10-bit track HDR10,
        // and plenty of 10-bit HEVC is plain SDR.
        let isDolbyVision = track.dovi != nil
            || ["dvh1", "dvhe"].contains(fourCharString(track.mediaSubType.rawValue).lowercased())
        return PlayerVideoInfo(
            width: width,
            height: height,
            fps: fps,
            codec: codec,
            dynamicRange: PlayerDynamicRange(transfer: track.transferFunction, isDolbyVision: isDolbyVision)
        )
    }

    /// The playing audio format and the current bitrate. KSAVPlayer reports no
    /// bitrate (`dynamicInfo` is nil there), so its chip stays hidden.
    static func streamSample(from layer: KSPlayerLayer?) -> PlayerStreamSample? {
        guard let player = layer?.player else { return nil }
        let audioTracks = player.tracks(mediaType: .audio)
        let audio = (audioTracks.first { $0.isEnabled } ?? audioTracks.first).map { audioInfo(for: $0) }
        let bits = player.dynamicInfo.map { $0.videoBitrate + $0.audioBitrate } ?? 0
        return PlayerStreamSample(audio: audio, bitsPerSecond: bits > 0 ? Double(bits) : nil)
    }

    private static func audioInfo(for track: any MediaPlayerTrack) -> PlayerAudioInfo {
        let channels = Int(track.audioStreamBasicDescription?.mChannelsPerFrame ?? 0)
        let codec: String? = if let ffmpeg = track as? FFmpegAssetTrack, !ffmpeg.codecName.isEmpty {
            ffmpeg.codecName
        } else {
            track.formatDescription.map { fourCharString(CMFormatDescriptionGetMediaSubType($0)) }
        }
        return PlayerAudioInfo(codec: codec?.isEmpty == false ? codec : nil, channels: channels)
    }

    // MARK: - Codec naming

    private static func codecName(for track: some MediaPlayerTrack) -> String? {
        guard let format = track.formatDescription else {
            return track.name.isEmpty ? nil : track.name
        }
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMVideoCodecType_HEVC:
            return "HEVC"
        case kCMVideoCodecType_H264:
            return "H264"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes4444:
            return "ProRes"
        case let subType:
            let fourCC = fourCharString(subType)
            if !fourCC.isEmpty { return fourCC.uppercased() }
            return track.name.isEmpty ? nil : track.name
        }
    }

    private static func fourCharString(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let printable = bytes.filter { $0 >= 0x20 && $0 < 0x7F }.map { Character(UnicodeScalar($0)) }
        return String(printable).trimmingCharacters(in: .whitespaces)
    }
}

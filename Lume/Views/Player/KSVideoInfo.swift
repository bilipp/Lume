//
//  KSVideoInfo.swift
//  Lume
//
//  Video-track introspection for the KSPlayer engine, shared by every platform.
//
//  KSPlayer is the default engine, so this must stay ungated: the tvOS overlay
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
        return (width > 0 && height > 0)
            ? PlayerVideoInfo(width: width, height: height, fps: fps, codec: codecName(for: track))
            : nil
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

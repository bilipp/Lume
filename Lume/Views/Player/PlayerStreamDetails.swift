//
//  PlayerStreamDetails.swift
//  Lume
//
//  The stream details the Advanced stream-info chips show beyond the picture
//  size: the HDR type, the audio format and the bitrate. Engine-agnostic; each
//  engine maps what it reports onto these and leaves out what it doesn't.
//
//  Labels are technical names only — never a Dolby word mark ("DV", "E-AC-3",
//  "TrueHD").
//

import Foundation

/// The HDR type of the video. SDR has no case: the chips show HDR types only.
nonisolated enum PlayerDynamicRange: Equatable {
    case hdr10
    case hdr10Plus
    case hlg
    case dolbyVision

    var label: String {
        switch self {
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10+"
        case .hlg: "HLG"
        case .dolbyVision: "DV"
        }
    }

    /// From a transfer-characteristic name as FFmpeg, CoreMedia or AVFoundation
    /// spell it (`smpte2084`, `SMPTE_ST_2084_PQ`, `arib-std-b67`, `ITU_R_2100_HLG`).
    /// Anything else — BT.709, an unknown name — is SDR, so `nil`.
    init?(transfer: String?, isDolbyVision: Bool = false) {
        if isDolbyVision {
            self = .dolbyVision
            return
        }
        guard let key = transfer?.lowercased().filter({ $0.isLetter || $0.isNumber }) else { return nil }
        if key.contains("2084") || key.hasSuffix("pq") {
            self = .hdr10
        } else if key.contains("b67") || key.contains("hlg") {
            self = .hlg
        } else {
            return nil
        }
    }

    /// From the ITU-T H.273 transfer-characteristics code (16 = PQ, 18 = HLG).
    init?(transferCode: Int, isDolbyVision: Bool = false) {
        if isDolbyVision {
            self = .dolbyVision
            return
        }
        switch transferCode {
        case 16: self = .hdr10
        case 18: self = .hlg
        default: return nil
        }
    }
}

/// The playing audio track's format, as far as the engine reports it.
nonisolated struct PlayerAudioInfo: Equatable {
    let codec: String?
    let channels: Int

    /// e.g. `E-AC-3 5.1`, `AAC Stereo`, or just one half when the other is
    /// unknown. `nil` when neither is.
    var label: String? {
        let parts = [codec.flatMap(PlayerCodecLabel.audio), layout].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The same for VoiceOver, which reads "5.1" as a number: "E-AC-3, 5.1
    /// surround".
    var spokenLabel: String? {
        let spokenLayout: String? = switch channels {
        case 6: String(localized: "5.1 surround")
        case 8: String(localized: "7.1 surround")
        default: layout
        }
        let parts = [codec.flatMap(PlayerCodecLabel.audio), spokenLayout].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The channel layout in the words a viewer knows; counts with no common
    /// name (3, 4, 5, 7 …) are left out rather than shown as a bare number.
    var layout: String? {
        switch channels {
        case 1: String(localized: "Mono")
        case 2: String(localized: "Stereo")
        case 6: "5.1"
        case 8: "7.1"
        default: nil
        }
    }
}

/// One reading of the values that change while a stream plays, taken by the
/// stream-info chips about once a second while they are on screen.
nonisolated struct PlayerStreamSample: Equatable {
    var audio: PlayerAudioInfo?
    /// The stream's current bitrate, video and audio together. `nil` when the
    /// engine has no reading yet or reports none.
    var bitsPerSecond: Double?
}

/// An engine coordinator the stream-info chips can sample. Pulled, never
/// pushed: the coordinator publishes nothing new, so the player tree doesn't
/// re-render once a second — only the chip row does, and only while it shows.
protocol PlayerStreamSampling: AnyObject {
    func streamSample() -> PlayerStreamSample?
}

/// Short, familiar codec names for the chips, from whatever spelling an engine
/// reports (FFmpeg names, fourccs, VLC's).
nonisolated enum PlayerCodecLabel {
    static func video(_ raw: String) -> String? {
        let key = normalized(raw)
        guard !key.isEmpty else { return nil }
        return videoNames[key] ?? key.uppercased()
    }

    static func audio(_ raw: String) -> String? {
        let key = normalized(raw)
        guard !key.isEmpty else { return nil }
        return audioNames[key] ?? key.uppercased()
    }

    /// A fourcc packed little-endian, first character in the low byte, as
    /// libVLC reports them (`'h264'`, `'a52 '`).
    static func fourCC(_ value: UInt32) -> String? {
        guard value != 0 else { return nil }
        let bytes = (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        guard bytes.allSatisfy({ $0 == 0 || (0x20 ..< 0x7F).contains($0) }) else { return nil }
        let text = String(bytes: bytes.filter { $0 != 0 }, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces)
        return text?.isEmpty == false ? text : nil
    }

    /// Lowercased, without FFmpeg's profile suffix (`aac (LC)`, `h264 (High)`).
    private static func normalized(_ raw: String) -> String {
        let name = raw.split(separator: "(", maxSplits: 1).first.map(String.init) ?? ""
        return name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static let videoNames = [
        "hevc": "HEVC", "h265": "HEVC", "hvc1": "HEVC", "hev1": "HEVC", "dvh1": "HEVC", "dvhe": "HEVC",
        "h264": "H.264", "avc": "H.264", "avc1": "H.264", "x264": "H.264",
        "av1": "AV1", "av01": "AV1", "vp9": "VP9", "vp09": "VP9", "vp90": "VP9", "vp8": "VP8", "vp80": "VP8",
        "mpeg2video": "MPEG-2", "mpgv": "MPEG-2", "mp2v": "MPEG-2", "mpeg4": "MPEG-4", "mp4v": "MPEG-4",
        "prores": "ProRes", "apch": "ProRes", "apcn": "ProRes", "vc1": "VC-1", "wvc1": "VC-1"
    ]

    private static let audioNames = [
        "eac3": "E-AC-3", "e-ac-3": "E-AC-3", "ec-3": "E-AC-3", "ec3": "E-AC-3",
        "ac3": "AC-3", "ac-3": "AC-3", "a52": "AC-3", "a52b": "AC-3",
        "truehd": "TrueHD", "trhd": "TrueHD", "mlp": "TrueHD",
        "dts": "DTS", "dtsc": "DTS", "dtsh": "DTS", "dtsl": "DTS", "ac4": "AC-4", "ac-4": "AC-4",
        "aac": "AAC", "mp4a": "AAC", "aach": "AAC", "aacl": "AAC", "aac_latm": "AAC", "flac": "FLAC", "opus": "Opus", "vorbis": "Vorbis",
        "mp3": "MP3", "mpga": "MP3", "mp3float": "MP3", "mp2": "MP2",
        "alac": "ALAC", "lpcm": "PCM", "pcm_s16le": "PCM", "pcm_s24le": "PCM", "araw": "PCM"
    ]
}

/// The bitrate in the two units viewers see on speed tests.
nonisolated enum PlayerBitrateText {
    /// `8.4 Mbit/s` from one megabit up, `640 kbit/s` below. `nil` for no
    /// reading, so the chip collapses rather than showing "0 kbit/s".
    static func text(bitsPerSecond: Double?) -> String? {
        guard let value = formattedValue(bitsPerSecond) else { return nil }
        return value.isMegabits
            ? String(localized: "\(value.number) Mbit/s")
            : String(localized: "\(value.number) kbit/s")
    }

    static func spoken(bitsPerSecond: Double?) -> String? {
        guard let value = formattedValue(bitsPerSecond) else { return nil }
        return value.isMegabits
            ? String(localized: "\(value.number) megabits per second")
            : String(localized: "\(value.number) kilobits per second")
    }

    private static func formattedValue(_ bitsPerSecond: Double?) -> (number: String, isMegabits: Bool)? {
        guard let bitsPerSecond, bitsPerSecond.isFinite, bitsPerSecond >= 1000 else { return nil }
        // Rounded to the shown precision first, so 999.6 kbit/s reads "1.0 Mbit/s"
        // rather than "1,000 kbit/s".
        if (bitsPerSecond / 1000).rounded() >= 1000 {
            let megabits = bitsPerSecond / 1_000_000
            return (megabits.formatted(.number.precision(.fractionLength(1))), true)
        }
        let kilobits = (bitsPerSecond / 1000).rounded()
        return (kilobits.formatted(.number.precision(.fractionLength(0))), false)
    }
}

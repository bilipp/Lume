import Foundation
@testable import Lume
import Testing

/// Units and decimal separators are localized; exact English wording is only
/// asserted on an English host.
private nonisolated func isEnglishHost() -> Bool {
    (Locale.preferredLanguages.first?.hasPrefix("en") ?? false) && Locale.current.decimalSeparator == "."
}

struct PlayerStreamDetailsTests {
    // MARK: - Codec labels

    @Test(arguments: [
        ("h264", "H.264"), ("H264", "H.264"), ("h264 (High)", "H.264"), ("avc1", "H.264"),
        ("hevc", "HEVC"), ("hvc1", "HEVC"), ("av1", "AV1"), ("vp9", "VP9"), ("mpeg2video", "MPEG-2")
    ])
    func `video codec names read the familiar way`(raw: String, expected: String) {
        #expect(PlayerCodecLabel.video(raw) == expected)
    }

    @Test(arguments: [
        ("eac3", "E-AC-3"), ("ac3", "AC-3"), ("a52 ", "AC-3"), ("aac (LC)", "AAC"), ("mp4a", "AAC"),
        ("truehd", "TrueHD"), ("dts", "DTS"), ("opus", "Opus"), ("mp3float", "MP3")
    ])
    func `audio codec names read the familiar way`(raw: String, expected: String) {
        #expect(PlayerCodecLabel.audio(raw) == expected)
    }

    @Test func `unknown codecs fall back to the uppercased name`() {
        #expect(PlayerCodecLabel.video("theora") == "THEORA")
        #expect(PlayerCodecLabel.audio("speex") == "SPEEX")
    }

    @Test func `empty codec names produce no label`() {
        #expect(PlayerCodecLabel.video("") == nil)
        #expect(PlayerCodecLabel.audio("  ") == nil)
    }

    @Test func `fourcc decodes little endian and trims padding`() {
        // 'h264' with 'h' in the low byte, as libVLC packs it.
        let h264: UInt32 = 0x3436_3268
        #expect(PlayerCodecLabel.fourCC(h264) == "h264")
        // 'a52 ' — trailing space trimmed.
        let a52: UInt32 = 0x2032_3561
        #expect(PlayerCodecLabel.fourCC(a52) == "a52")
        #expect(PlayerCodecLabel.fourCC(0) == nil)
        #expect(PlayerCodecLabel.fourCC(0xFFFF_FFFF) == nil)
    }

    // MARK: - HDR

    @Test(arguments: [
        ("smpte2084", PlayerDynamicRange.hdr10), ("SMPTE_ST_2084_PQ", .hdr10),
        ("arib-std-b67", .hlg), ("ITU_R_2100_HLG", .hlg)
    ])
    func `transfer names map to the HDR type`(transfer: String, expected: PlayerDynamicRange) {
        #expect(PlayerDynamicRange(transfer: transfer) == expected)
    }

    @Test func `SDR and unknown transfers have no HDR type`() {
        #expect(PlayerDynamicRange(transfer: "bt709") == nil)
        #expect(PlayerDynamicRange(transfer: "ITU_R_709_2") == nil)
        #expect(PlayerDynamicRange(transfer: nil) == nil)
        #expect(PlayerDynamicRange(transferCode: 1) == nil)
    }

    @Test func `transfer codes map to the HDR type`() {
        #expect(PlayerDynamicRange(transferCode: 16) == .hdr10)
        #expect(PlayerDynamicRange(transferCode: 18) == .hlg)
    }

    @Test func `dolby vision wins over the transfer`() {
        #expect(PlayerDynamicRange(transfer: "smpte2084", isDolbyVision: true) == .dolbyVision)
        #expect(PlayerDynamicRange(transferCode: 1, isDolbyVision: true) == .dolbyVision)
        #expect(PlayerDynamicRange.dolbyVision.label == "DV")
    }

    @Test func `HDR type joins the video badges`() {
        let info = PlayerVideoInfo(width: 3840, height: 2160, fps: 24, codec: "hevc", dynamicRange: .hlg)
        #expect(info.badgeParts == ["4K", "HEVC", "HLG"])
    }

    // MARK: - Audio

    @Test(.enabled(if: isEnglishHost()))
    func `audio label pairs codec and layout`() {
        #expect(PlayerAudioInfo(codec: "eac3", channels: 6).label == "E-AC-3 5.1")
        #expect(PlayerAudioInfo(codec: "aac", channels: 2).label == "AAC Stereo")
        #expect(PlayerAudioInfo(codec: "ac3", channels: 1).label == "AC-3 Mono")
        #expect(PlayerAudioInfo(codec: "truehd", channels: 8).label == "TrueHD 7.1")
    }

    @Test func `uncommon channel counts are left out`() {
        #expect(PlayerAudioInfo(codec: "aac", channels: 3).label == "AAC")
        #expect(PlayerAudioInfo(codec: nil, channels: 6).label == "5.1")
        #expect(PlayerAudioInfo(codec: nil, channels: 0).label == nil)
    }

    @Test(.enabled(if: isEnglishHost()))
    func `spoken audio label spells out surround`() {
        #expect(PlayerAudioInfo(codec: "eac3", channels: 6).spokenLabel == "E-AC-3, 5.1 surround")
        #expect(PlayerAudioInfo(codec: "aac", channels: 2).spokenLabel == "AAC, Stereo")
    }

    // MARK: - Bitrate

    @Test(.enabled(if: isEnglishHost()))
    func `bitrate reads in megabits from one megabit up`() {
        #expect(PlayerBitrateText.text(bitsPerSecond: 8_400_000) == "8.4 Mbit/s")
        #expect(PlayerBitrateText.text(bitsPerSecond: 1_000_000) == "1.0 Mbit/s")
        #expect(PlayerBitrateText.spoken(bitsPerSecond: 8_400_000) == "8.4 megabits per second")
    }

    @Test(.enabled(if: isEnglishHost()))
    func `bitrate below a megabit reads in kilobits`() {
        #expect(PlayerBitrateText.text(bitsPerSecond: 640_000) == "640 kbit/s")
        #expect(PlayerBitrateText.spoken(bitsPerSecond: 640_000) == "640 kilobits per second")
    }

    @Test(.enabled(if: isEnglishHost()))
    func `bitrate that rounds to a thousand kilobits reads as a megabit`() {
        #expect(PlayerBitrateText.text(bitsPerSecond: 999_600) == "1.0 Mbit/s")
        #expect(PlayerBitrateText.text(bitsPerSecond: 999_400) == "999 kbit/s")
    }

    @Test func `no usable bitrate collapses the chip`() {
        #expect(PlayerBitrateText.text(bitsPerSecond: nil) == nil)
        #expect(PlayerBitrateText.text(bitsPerSecond: 0) == nil)
        #expect(PlayerBitrateText.text(bitsPerSecond: 999) == nil)
        #expect(PlayerBitrateText.text(bitsPerSecond: .infinity) == nil)
        #expect(PlayerBitrateText.text(bitsPerSecond: .nan) == nil)
    }
}

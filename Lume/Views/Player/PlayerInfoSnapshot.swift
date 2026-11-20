//
//  PlayerInfoSnapshot.swift
//  Lume
//
//  The in-player stream-information caption, derived once from pure values.
//
//  Platform-neutral on purpose: the tvOS overlay and the iOS / iPadOS / macOS /
//  visionOS caption both read this, so the two surfaces can never drift. It
//  takes only value snapshots — never a SwiftData model, never the playback
//  clock — so a caller can build it in a body without paying for a fetch or
//  re-rendering on every tick.
//

import Foundation

struct PlayerInfoSnapshot: Equatable {
    /// The one separator every caption surface joins with — declared here so
    /// the tvOS overlay and the non-tvOS leaf can't drift apart on it.
    static let separator = "  ·  "

    private let isLive: Bool
    private let isSeries: Bool
    private let mediaSubtitle: String?
    private let details: StreamInfoDetails?
    private let videoInfo: PlayerVideoInfo?
    private let engine: PlayerEngineKind?
    private let detailLevel: StreamInfoDetailLevel

    /// - Parameters:
    ///   - details: programme-level context resolved by `PlayerStreamInfo`.
    ///     `nil` before the resolve lands, and on hosts that resolve none.
    ///   - engine: the engine the Advanced readout names. `nil` drops that
    ///     chip.
    init(
        media: PlayableMedia,
        details: StreamInfoDetails?,
        videoInfo: PlayerVideoInfo?,
        engine: PlayerEngineKind?,
        detailLevel: StreamInfoDetailLevel
    ) {
        isLive = media.isLive
        isSeries = if case .episode = media.contentRef {
            true
        } else {
            false
        }
        mediaSubtitle = media.subtitle
        self.details = details
        self.videoInfo = videoInfo
        self.engine = engine
        self.detailLevel = detailLevel
    }

    /// The line above the title: what's on now for live TV, the series name for
    /// an episode, nothing for a movie.
    var topCaption: String? {
        if isLive {
            return details?.epg?.current?.title
        }
        if isSeries {
            return mediaSubtitle
        }
        return nil
    }

    /// The programme line: what's on now (or the series name), then the
    /// playlist that owns the stream. Shown at both detail levels — the
    /// playlist is programme context, not part of the technical readout.
    var programmeCaption: String? {
        let parts = [topCaption, details?.playlistName]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: Self.separator)
    }

    /// The Advanced readout as chips, in reading order: picture, then sound,
    /// then the live bitrate, then the engine — e.g.
    /// `4K` `HEVC` `HDR10` `50 fps` `E-AC-3 5.1` `8.4 Mbit/s` `Aether`.
    /// Empty at `.simple`. Anything an engine doesn't report is left out, so
    /// a chip never shows a placeholder.
    func techChips(sample: PlayerStreamSample?) -> [String] {
        guard detailLevel == .advanced else { return [] }
        var chips = videoInfo?.captionParts ?? []
        if let audio = sample?.audio?.label {
            chips.append(audio)
        }
        if let bitrate = PlayerBitrateText.text(bitsPerSecond: sample?.bitsPerSecond) {
            chips.append(bitrate)
        }
        if let engineName = engine?.displayName, !engineName.isEmpty {
            chips.append(engineName)
        }
        return chips
    }

    /// The programme line phrased for VoiceOver ("Playing …, Playlist …").
    var spokenProgrammeParts: [String] {
        var spoken: [String] = []
        if let programme = topCaption, !programme.isEmpty {
            spoken.append(String(localized: "Playing \(programme)"))
        }
        if let playlistName = details?.playlistName, !playlistName.isEmpty {
            spoken.append(String(localized: "Playlist \(playlistName)"))
        }
        return spoken
    }

    /// The chips phrased for one spoken VoiceOver label, with the
    /// abbreviations spelled out ("24 frames per second", not "24 f p s").
    func spokenTechParts(sample: PlayerStreamSample?) -> [String] {
        guard detailLevel == .advanced else { return [] }
        var spoken = videoInfo?.spokenCaptionParts ?? []
        if let audio = sample?.audio?.spokenLabel {
            spoken.append(audio)
        }
        if let bitrate = PlayerBitrateText.spoken(bitsPerSecond: sample?.bitsPerSecond) {
            spoken.append(bitrate)
        }
        if let engineName = engine?.displayName, !engineName.isEmpty {
            spoken.append(engineName)
        }
        return spoken
    }

    /// The video-derived half of the info panel's badge row. Callers prepend
    /// their own badges (tvOS leads with the content rating).
    var infoBadges: [String] {
        videoInfo?.badgeParts ?? []
    }
}

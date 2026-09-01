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
    ///   - engine: the engine the Advanced readout names. `nil` where the host
    ///     surfaces no engine name (tvOS), which drops that part entirely.
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

    /// The programme half of the caption: what's on now (or the series name),
    /// then the playlist that owns the stream. Shown at both detail levels —
    /// the playlist is programme context, not part of the technical readout.
    /// tvOS renders this alone, with `techCaption` right-aligned opposite it.
    var programmeCaption: String? {
        let parts = [topCaption, details?.playlistName]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: Self.separator)
    }

    /// The right-aligned technical readout, e.g. `4K  ·  H264  ·  24 fps`.
    /// Empty at `.simple`, and while no video track has reported usable
    /// dimensions yet.
    var techCaption: String {
        guard detailLevel == .advanced else { return "" }
        return videoInfo?.captionParts.joined(separator: Self.separator) ?? ""
    }

    /// Every element on one line, as the non-tvOS caption renders it.
    var caption: String {
        captionParts.joined(separator: Self.separator)
    }

    /// The ordered, already-localized, already-non-empty caption elements.
    /// Anything without a value is dropped rather than contributing an empty
    /// slot, so a renderer can join these without ever emitting a stray
    /// separator — which is the common case: AVPlayer reports no codec and no
    /// frame rate, and a live channel with no matched XMLTV has no programme.
    var captionParts: [String] {
        var parts = [
            topCaption,
            details?.playlistName,
            details?.categoryName
        ].compactMap(\.self).filter { !$0.isEmpty }

        guard detailLevel == .advanced else { return parts }

        parts.append(contentsOf: videoInfo?.captionParts ?? [])
        if let engineName = engine?.displayName, !engineName.isEmpty {
            parts.append(engineName)
        }
        return parts
    }

    /// The same elements in the same order, phrased for a single spoken
    /// VoiceOver label: one sentence instead of the five fragments the `·`
    /// separators would otherwise be read as, with the abbreviations spelled
    /// out ("24 frames per second", not "24 f p s").
    var spokenParts: [String] {
        var spoken: [String] = []
        if let programme = topCaption, !programme.isEmpty {
            spoken.append(String(localized: "Playing \(programme)"))
        }
        if let playlistName = details?.playlistName, !playlistName.isEmpty {
            spoken.append(String(localized: "Playlist \(playlistName)"))
        }
        if let categoryName = details?.categoryName, !categoryName.isEmpty {
            spoken.append(categoryName)
        }
        if detailLevel == .advanced {
            spoken.append(contentsOf: videoInfo?.spokenCaptionParts ?? [])
            if let engineName = engine?.displayName {
                spoken.append(engineName)
            }
        }
        return spoken
    }

    /// The video-derived half of the info panel's badge row. Callers prepend
    /// their own badges (tvOS leads with the content rating).
    var infoBadges: [String] {
        videoInfo?.badgeParts ?? []
    }
}

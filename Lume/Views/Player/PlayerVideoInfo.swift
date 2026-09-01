import Foundation

/// Resolution / frame-rate / codec snapshot for the current video track.
///
/// Engine-agnostic: produced by both the VLCKit coordinator and the KSPlayer
/// adapter, and consumed by the shared player overlay.
/// One selectable audio or subtitle track, flattened to what the player
/// overlays' menus need. Engines map their native track types onto this so the
/// menu code stays identical regardless of the backing player.
///
/// Engine-agnostic and unguarded by platform: the shared tvOS overlay
/// (`TVPlayerControlsOverlay`) and the AVPlayer iOS / macOS overlay both consume
/// it, and the AVPlayer coordinator produces it on every platform.
struct PlayerTrackOption: Identifiable, Hashable {
    /// Opaque, engine-defined identifier handed back to `select…Track(id:)`.
    let id: String
    let label: String
    let isSelected: Bool
}

nonisolated struct PlayerVideoInfo: Equatable {
    let width: Int
    let height: Int
    let fps: Double
    let codec: String?

    /// A short marketing-style quality tag derived from the pixel width.
    ///
    /// Keyed off width rather than height because many films are wider than
    /// 16:9 (e.g. a 4K scope feature is 3840×1608) — keying off height would
    /// drop such a title into a lower bucket ("1440p") even though it's 4K.
    var qualityTag: String {
        switch width {
        case 7680...: "8K"
        case 3840 ..< 7680: "4K"
        case 2560 ..< 3840: "1440p"
        case 1920 ..< 2560: "1080p"
        case 1280 ..< 1920: "720p"
        case 854 ..< 1280: "480p"
        case 1 ..< 854: "SD"
        default: ""
        }
    }

    /// Compact pieces for the overlay's right-hand technical caption, e.g.
    /// `["4K", "H264", "24 fps"]`.
    var captionParts: [String] {
        var parts = badgeParts
        if let frameRateText {
            parts.append(String(localized: "\(frameRateText) fps"))
        }
        return parts
    }

    /// The same pieces with the abbreviations spelled out, for the caption's
    /// single VoiceOver label — "24 frames per second", never "24 f p s".
    var spokenCaptionParts: [String] {
        var parts = badgeParts
        if let frameRateText {
            parts.append(String(localized: "\(frameRateText) frames per second"))
        }
        return parts
    }

    /// The quality tag and codec alone — the caption's leading pieces, and the
    /// whole of the info panel's video badge row.
    var badgeParts: [String] {
        var parts: [String] = []
        if !qualityTag.isEmpty { parts.append(qualityTag) }
        if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        return parts
    }

    /// `nil` when no usable rate has been reported — AVPlayer never reports one,
    /// so the part collapses instead of rendering "0 fps".
    private var frameRateText: String? {
        guard fps > 0 else { return nil }
        // Locale-aware: `String(format:)` would force a period decimal
        // separator, which is wrong in de/fr/es/pt/it. Integral rates still
        // render bare ("24"), fractional ones to two places ("23.98").
        let rounded = (fps * 100).rounded() / 100
        let places = rounded.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return rounded.formatted(.number.precision(.fractionLength(places)))
    }
}

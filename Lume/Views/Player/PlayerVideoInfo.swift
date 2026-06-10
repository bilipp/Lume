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

struct PlayerVideoInfo: Equatable {
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
        var parts: [String] = []
        if !qualityTag.isEmpty { parts.append(qualityTag) }
        if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        if fps > 0 {
            let rounded = (fps * 100).rounded() / 100
            let text = rounded.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", rounded)
                : String(format: "%.2f", rounded)
            parts.append("\(text) fps")
        }
        return parts
    }
}

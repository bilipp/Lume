import Foundation

/// What a Chromecast receiver can be asked to play.
///
/// The receiver fetches the stream itself, over the network, and decodes it with
/// a fixed set of containers — so unlike the local engines (KSPlayer/VLCKit open
/// nearly anything, from a `file://` download to MKV) a cast target rejects a
/// good share of what Lume plays. Deciding that up front matters because the
/// failure mode is otherwise invisible: the host unmounts the local engine for
/// the cast, and a receiver that never starts leaves a poster and a frozen
/// scrubber with nothing to explain it.
///
/// This is deliberately *conservative about rejecting*: only containers known
/// not to work are refused. Anything unrecognised is handed over with no
/// declared MIME type so the receiver can sniff it, and the runtime failure path
/// (`CastFailure`) catches it if that doesn't work out. Two things can't be
/// judged from a URL at all and are left to that path:
///
/// - **CORS.** Google's receiver requires `Access-Control-Allow-Origin` on
///   adaptive streams (HLS/DASH); IPTV providers rarely send it, so an `.m3u8`
///   that looks perfectly castable here may still be refused.
/// - **Codecs.** The container can be supported while its contents aren't —
///   HEVC inside MPEG-TS is the common IPTV case.
///
/// Pure and `nonisolated` so it can be unit-tested without the Cast SDK, which
/// is iOS-only and not linked into the test host on other platforms.
nonisolated enum CastCompatibility {
    /// Why a stream can't be handed to a receiver.
    enum Rejection: Equatable {
        /// Not something a receiver can fetch: a local download (`file://`) or an
        /// unresolved placeholder (`lumestalker://`). The receiver pulls the
        /// stream over the network on its own, so it can reach neither.
        case notRemote
        /// A container the receiver has no demuxer for (MKV, AVI, …).
        case unsupportedContainer(String)
    }

    enum Verdict: Equatable {
        /// Castable. `contentType` is the MIME type to declare, or `nil` to let
        /// the receiver sniff an unrecognised container.
        case castable(contentType: String?)
        case rejected(Rejection)

        var isCastable: Bool {
            if case .castable = self {
                return true
            }
            return false
        }
    }

    /// Containers the Default Media Receiver plays, mapped to the MIME type to
    /// declare. Per Google's supported-media list: MP4, MP2T, WebM, MP3, WAV,
    /// OGG, plus the HLS/DASH manifest types.
    private static let supported: [String: String] = [
        "mp4": "video/mp4",
        "m4v": "video/mp4",
        "ts": "video/mp2t",
        "mts": "video/mp2t",
        "m2ts": "video/mp2t",
        "webm": "video/webm",
        "m3u8": "application/x-mpegurl",
        "mpd": "application/dash+xml",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "ogg": "video/ogg",
        "ogv": "video/ogg"
    ]

    /// Containers known not to play, so the user gets told instead of watching a
    /// poster forever. Scoped to what actually turns up in IPTV catalogues —
    /// anything outside both lists is attempted rather than refused.
    private static let unsupported: Set<String> = [
        "mkv", "avi", "flv", "wmv", "vob", "rmvb", "rm",
        "asf", "divx", "mpg", "mpeg", "m2v", "3gp", "ogm"
    ]

    /// Judge a stream URL. See the type's note for what this deliberately
    /// can't decide.
    static func evaluate(_ url: URL) -> Verdict {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .rejected(.notRemote)
        }
        let ext = url.pathExtension.lowercased()
        if let contentType = supported[ext] {
            return .castable(contentType: contentType)
        }
        if unsupported.contains(ext) {
            return .rejected(.unsupportedContainer(ext))
        }
        // Unrecognised or extensionless (Xtream live URLs often have no
        // extension at all) — hand it over undeclared and let the receiver
        // decide. Declaring a guessed MIME type here is worse than declaring
        // none: the receiver trusts it.
        return .castable(contentType: nil)
    }
}

/// A receiver's refusal of the stream it was asked to play, reported by the
/// `CastProvider` so the host can fall back to local playback and say so.
nonisolated struct CastFailure: Equatable, Sendable {
    /// The stream that failed. The host checks this against what's on screen so
    /// a failure landing after the viewer switched titles is ignored.
    let url: URL

    /// Log detail. Not user-facing — the UI says one thing for every cause,
    /// because "the TV won't play this" is the only actionable part.
    let detail: String
}

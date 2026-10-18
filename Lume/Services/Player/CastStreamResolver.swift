//
//  CastStreamResolver.swift
//  Lume
//
//  The single answer to "can this be sent to a Cast receiver, and as what".
//  Rejects up front only what can never play there; anything that passes is
//  still tried, and a receiver load failure falls back to local playback.
//

import Foundation

nonisolated enum CastStreamResolver {
    enum Verdict: Hashable {
        case castable(CastMediaRequest)
        case unsupported(Reason)
    }

    enum Reason: Hashable, CaseIterable {
        /// A download lives on this device; the receiver can't reach it.
        case localFile
        /// A recording plays from a short-lived grant on the recording server.
        case recording
        /// The source authenticates per request with headers the receiver
        /// can't send, and its token must never move into the URL.
        case headerAuth
        /// A Stalker `lumestalker://` placeholder that `create_link` hasn't
        /// turned into a real stream URL yet.
        case needsResolution
        /// Not HTTP(S) — RTMP, RTSP, UDP and the like.
        case unsupportedProtocol
        /// A container the receiver has no player for.
        case unsupportedFormat
    }

    /// Containers the Default Media Receiver can't demux at all.
    static let unsupportedExtensions: Set<String> = [
        "avi", "divx", "flv", "wmv", "asf", "rm", "rmvb", "vob", "mpg", "mpeg", "iso"
    ]

    /// Whether `media` can be cast and, if so, the request to load.
    ///
    /// Pass the media the player is actually showing, so a Stalker item is
    /// already resolved. `position` is where a VOD cast starts (live always
    /// starts at 0; omitted, the media's own start time); `preferredURL`
    /// replaces the played URL with one that casts better — see
    /// `preferredLiveURL(for:playlist:client:)`.
    static func verdict(
        for media: PlayableMedia,
        at position: TimeInterval? = nil,
        preferredURL: URL? = nil
    ) -> Verdict {
        let url = preferredURL ?? media.url
        if let reason = rejection(for: media, url: url) {
            return .unsupported(reason)
        }
        return .castable(CastMediaRequest(
            contentURL: url,
            contentType: CastMediaRequest.contentType(for: url, kind: media.kind),
            streamType: media.isLive ? .live : .buffered,
            title: media.title,
            subtitle: media.subtitle,
            posterURL: CastMediaRequest.receiverPosterURL(media.posterURL),
            startTime: media.isLive ? 0 : max(0, position ?? media.startTime),
            contentRef: media.contentRef
        ))
    }

    private static func rejection(for media: PlayableMedia, url: URL) -> Reason? {
        if media.contentRef.isRecording { return .recording }
        if media.url.isFileURL || url.isFileURL { return .localFile }
        if media.httpHeaders != nil { return .headerAuth }
        if StalkerLink.isPlaceholder(url) { return .needsResolution }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .unsupportedProtocol
        }
        if unsupportedExtensions.contains(url.pathExtension.lowercased()) { return .unsupportedFormat }
        return nil
    }

    /// The URL to cast an Xtream live channel at instead of the one the
    /// player opened, or `nil` to cast the played URL unchanged.
    ///
    /// Receivers play HLS far more reliably than raw MPEG-TS, so the cast asks
    /// for HLS even when the playlist is set to MPEG-TS for local playback —
    /// unless the account's `allowed_output_formats` rule HLS out. A channel
    /// with its own `directURL` keeps it, as it does in
    /// `LiveStreamURLResolver.playbackURL`.
    static func preferredLiveURL(
        for stream: LiveStream,
        playlist: Playlist,
        client: XtreamClient = XtreamClient()
    ) -> URL? {
        guard playlist.sourceType == .xtream, stream.directURL == nil else { return nil }
        if let allowed = playlist.allowedOutputFormats, !allowed.contains(StreamFormat.m3u8.rawValue) {
            return nil
        }
        return client.buildLiveStreamURL(for: stream, playlist: playlist, format: .m3u8)
    }
}

nonisolated extension CastStreamResolver.Reason {
    /// Why the Cast option is unavailable, shown beside the disabled control.
    var message: LocalizedStringResource {
        switch self {
        case .localFile:
            LocalizedStringResource(
                "player.cast.unavailable.local-file",
                defaultValue: "Downloaded videos can only play on this device.",
                comment: "Player › Cast sheet: why a downloaded video can't be sent to a Chromecast."
            )
        case .recording:
            LocalizedStringResource(
                "player.cast.unavailable.recording",
                defaultValue: "Recordings can't be cast.",
                comment: "Player › Cast sheet: why a recording from the recording server can't be sent to a Chromecast."
            )
        case .headerAuth:
            LocalizedStringResource(
                "player.cast.unavailable.header-auth",
                defaultValue: "This source needs a sign-in that Cast devices can't use.",
                comment: "Player › Cast sheet: why a stream from a signed-in media server or network share can't be sent to a Chromecast."
            )
        case .needsResolution:
            LocalizedStringResource(
                "player.cast.unavailable.needs-resolution",
                defaultValue: "This stream is still loading. Try again in a moment.",
                comment: "Player › Cast sheet: why a portal stream whose address isn't known yet can't be sent to a Chromecast."
            )
        case .unsupportedProtocol:
            LocalizedStringResource(
                "player.cast.unavailable.protocol",
                defaultValue: "Cast devices can't open this kind of stream.",
                comment: "Player › Cast sheet: why a stream using a protocol other than HTTP (e.g. RTMP, UDP) can't be sent to a Chromecast."
            )
        case .unsupportedFormat:
            LocalizedStringResource(
                "player.cast.unavailable.format",
                defaultValue: "Cast devices can't play this video format.",
                comment: "Player › Cast sheet: why a video in a container a Chromecast can't play (e.g. AVI, FLV) can't be sent to it."
            )
        }
    }
}

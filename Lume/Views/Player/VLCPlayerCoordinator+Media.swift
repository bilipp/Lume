//
//  VLCPlayerCoordinator+Media.swift
//  Lume
//
//  Builds the `VLCMedia` for a stream and applies the user's decoder/buffer
//  options to it, split out of VLCPlayerCoordinator to keep that file within
//  the project's size limit.
//

import Foundation
import VLCKit

extension VLCPlayerCoordinator {
    /// Every rebuild path goes through here: a fresh `VLCMedia` invalidates the
    /// track list, so the preferred-language latch must reset with it.
    func installMedia(_ url: URL, isLive: Bool) {
        // The credential-bearing MRL exists only for this call: it is never
        // stored back onto `mediaURL`, so it cannot reach a deep link, a Cast
        // payload, a download task description or window-restoration state.
        // VLCKit sends no headers, so every header-carrying source is folded
        // into the URL here: WebDAV's Basic userinfo, Jellyfin/Emby's api_key,
        // Plex's X-Plex-Token.
        let media = VLCMedia(url: HTTPBasicCredentials.authenticatedURL(url, headers: httpHeaders)
            ?? JellyfinPlaybackAuth.authenticatedURL(url, headers: httpHeaders)
            ?? PlexPlaybackAuth.authenticatedURL(url, headers: httpHeaders) ?? url)
        applyMediaOptions(to: media, isLive: isLive)
        mediaPlayer.media = media
        didApplyPreferredLanguages = false
    }

    private func applyMediaOptions(to media: VLCMedia?, isLive: Bool) {
        guard let media else { return }

        media.addOption(options.hardwareDecode ? ":avcodec-hw=videotoolbox" : ":avcodec-hw=none")
        media.addOption(":avcodec-threads=\(options.decodeThreads)")
        media.addOption(options.skipFrames ? ":skip-frames=1" : ":skip-frames=0")
        media.addOption(options.dropLateFrames ? ":drop-late-frames=1" : ":drop-late-frames=0")
        if options.httpReconnect { media.addOption(":http-reconnect=1") }

        media.addOption(options.deinterlace ? ":deinterlace=1" : ":deinterlace=0")
        if options.deinterlace { media.addOption(":deinterlace-mode=\(options.deinterlaceMode)") }

        // The original code set network-caching alongside the live/file caching
        // to the same value; the live and on-demand buffers keep that pairing.
        let buffer = isLive ? options.liveBuffer : options.vodBuffer
        media.addOption(":network-caching=\(buffer)")
        media.addOption(isLive ? ":live-caching=\(buffer)" : ":file-caching=\(buffer)")

        if let jitter = options.clockJitter { media.addOption(":clock-jitter=\(jitter)") }
        if let synchro = options.clockSynchro { media.addOption(":clock-synchro=\(synchro)") }
    }
}

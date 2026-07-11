//
//  VLCPlayerCoordinator+Stremio.swift
//  Lume
//
//  Stremio-sourced playback extras for the VLC engine: the request headers a
//  stream requires (`proxyHeaders`) and external subtitle tracks fetched from
//  subtitle addons. Split out of VLCPlayerCoordinator to keep that file
//  within the project's line-count cap.
//

import Foundation
import VLCKit

extension VLCPlayerCoordinator {
    /// Best-effort pass of the headers the source requires on the media
    /// request (Stremio `proxyHeaders`): libVLC has no arbitrary-header knob,
    /// only dedicated User-Agent / Referer options, so only those two are
    /// honored here. The other engines apply the full set — streams needing
    /// more than these two fail on VLC and fall through the engine chain.
    func applyRequestHeaders(to vlcMedia: VLCMedia?, from media: PlayableMedia) {
        guard let vlcMedia, let headers = media.httpHeaders else { return }
        for (name, value) in headers {
            switch name.lowercased() {
            case "user-agent":
                vlcMedia.addOption(":http-user-agent=\(value)")
            case "referer", "referrer":
                vlcMedia.addOption(":http-referrer=\(value)")
            default:
                break
            }
        }
    }

    /// Hands the media's external subtitle tracks (fetched from Stremio
    /// subtitle addons at resolution time) to libVLC as playback slaves; they
    /// join the stream's embedded tracks in the subtitle menu. Must run after
    /// `play()` — a slave added while the player has no media is dropped.
    func attachExternalSubtitles(from media: PlayableMedia) {
        for subtitle in media.externalSubtitles ?? [] {
            mediaPlayer.addPlaybackSlave(subtitle.url, type: .subtitle, enforce: false)
        }
    }
}

//
//  ExternalSubtitleLoading.swift
//  Lume
//
//  The engine-agnostic surface for side-loading a subtitle track that isn't
//  embedded in the stream — a file the OpenSubtitles search sheet hands back,
//  or a track a Stremio subtitle addon offered alongside the stream.
//
//  Each engine gets there differently (KSPlayer takes a `SubtitleInfo`, VLCKit
//  a "playback slave", LumeEngine an FFmpeg sidecar demux), so the conformances
//  live here side by side rather than scattered through four coordinators.
//  AVPlayer is the one engine that genuinely can't: `AVURLAsset` has no
//  sidecar-subtitle API, so it declares itself unsupported and the search entry
//  hides while it is driving playback (which, outside AirPlay, is the user's own
//  engine choice).
//

import Combine
import Foundation
import KSPlayer
import VLCKit

// `ExternalSubtitle`, the value both sources produce, lives next to
// `PlayableMedia` — addon tracks ride on the media itself.

@MainActor
protocol ExternalSubtitleLoading: AnyObject {
    /// Whether this engine can play a sidecar subtitle file at all. Drives
    /// whether the player overlay offers subtitle search.
    var supportsExternalSubtitles: Bool { get }

    /// Loads `subtitle` and makes it the active subtitle track.
    func loadExternalSubtitle(_ subtitle: ExternalSubtitle)
}

extension ExternalSubtitleLoading {
    var supportsExternalSubtitles: Bool {
        true
    }
}

// MARK: - KSPlayer

extension KSVideoPlayer.Coordinator: ExternalSubtitleLoading {
    func loadExternalSubtitle(_ subtitle: ExternalSubtitle) {
        let info = URLSubtitleInfo(subtitleID: subtitle.id, name: subtitle.label, url: subtitle.url)
        subtitleModel.addSubtitle(info: info)
        subtitleModel.selectedSubtitleInfo = info
    }
}

// MARK: - VLCKit

extension VLCPlayerCoordinator: ExternalSubtitleLoading {
    func loadExternalSubtitle(_ subtitle: ExternalSubtitle) {
        // `enforce: true` selects the new track immediately; VLC appends it to
        // `textTracks`, which the overlays re-read on the next render.
        mediaPlayer.addPlaybackSlave(subtitle.url, type: .subtitle, enforce: true)
        objectWillChange.send()
    }
}

// MARK: - AVPlayer

extension AVPlayerCoordinator: ExternalSubtitleLoading {
    /// `AVURLAsset` exposes only the legible media-selection groups the asset
    /// itself declares — there is no supported way to attach an SRT sidecar
    /// without rebuilding the asset as a composition, which would restart
    /// playback and still not work for the live/HLS sources this engine is
    /// mostly used for.
    var supportsExternalSubtitles: Bool {
        false
    }

    func loadExternalSubtitle(_: ExternalSubtitle) {}
}

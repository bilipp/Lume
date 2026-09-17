//
//  VLCPlayerCoordinator+MultiView.swift
//  Lume
//
//  The embedded (Multi-View tile) surface of `VLCPlayerCoordinator`. In its own
//  file because the coordinator is already at the project's file-length cap.
//

import VLCKit

extension VLCPlayerCoordinator {
    /// Multi-View tiles must be marked embedded *before* the container mounts:
    /// `attach(hostView:)` assigns the drawable, from which VLC may ask for the
    /// PiP media controller straight away — well ahead of any `onAppear`.
    convenience init(isEmbedded: Bool) {
        self.init()
        self.isEmbedded = isEmbedded
    }

    /// Silences this player without pausing it — Multi-View mutes every tile
    /// except the one carrying the audio. libVLC keeps decoding a muted track,
    /// which is what lets the audio move between tiles without a reload.
    var isMuted: Bool {
        get { mediaPlayer.audio?.isMuted ?? false }
        set { mediaPlayer.audio?.isMuted = newValue }
    }
}

//
//  VLCPlayerCoordinator+Volume.swift
//  Lume
//
//  The macOS player's app-level volume. In its own file because the
//  coordinator is already at the project's file-length cap.
//

import VLCKit

extension VLCPlayerCoordinator: PlayerVolumeApplying {
    func applyUserVolume(level: Float, muted: Bool) {
        userVolume = (level, muted)
        reapplyUserVolume()
    }

    /// `mediaPlayer.audio` drops what it is given until the audio output
    /// exists, so every state change applies the requested values again. Not
    /// `private`: called from the delegate in VLCPlayerCoordinator.swift.
    func reapplyUserVolume() {
        guard let audio = mediaPlayer.audio else { return }
        let volume = PlayerVolumeMath.vlcLevel(userVolume.level)
        if audio.volume != volume { audio.volume = volume }
        if audio.isMuted != userVolume.muted { audio.isMuted = userVolume.muted }
    }
}

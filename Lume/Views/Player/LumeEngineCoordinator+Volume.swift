//
//  LumeEngineCoordinator+Volume.swift
//  Lume
//
//  The macOS player's app-level volume. Split out of LumeEngineCoordinator to
//  keep that file within the project's size limit.
//

import Foundation
import LumeEngine

extension LumeEngineCoordinator: PlayerVolumeApplying {
    /// Mute goes through `isMuted`, which a full-screen session applies as a
    /// renderer mute; the audio lane is torn down only for Multi-View tiles.
    func applyUserVolume(level: Float, muted: Bool) {
        userVolume = level
        isMuted = muted
    }

    /// Every `configure` builds a new `PlayerSession`, which starts at full
    /// volume and unmuted. Not `private`: called from `configure` in
    /// LumeEngineCoordinator.swift.
    func applyAudioLevel(to session: PlayerSession) {
        session.renderer.isMuted = isMuted
        session.renderer.volume = userVolume
    }
}

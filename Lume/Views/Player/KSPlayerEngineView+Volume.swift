//
//  KSPlayerEngineView+Volume.swift
//  Lume
//
//  The macOS player's app-level volume on KSPlayer.
//

import KSPlayer

extension KSPlayerEngineView {
    /// `KSPlayerLayer.stop()` resets the volume on every zap and reconnect,
    /// and falling back to the second player drops the mute, so each stream
    /// takes the store's values again once it is ready.
    func reassertUserVolume(after state: KSPlayerState) {
        #if os(macOS)
            guard state == .readyToPlay || state == .bufferFinished, let playerVolume else { return }
            coordinator.applyUserVolume(level: playerVolume.level, muted: playerVolume.isMuted)
        #endif
    }
}

extension KSVideoPlayer.Coordinator: PlayerVolumeApplying {
    /// Writes the layer's player rather than the coordinator's `@Published`
    /// `playbackVolume` / `isMuted`, which would re-render the whole engine
    /// view on every slider tick and every rebuffer.
    func applyUserVolume(level: Float, muted: Bool) {
        guard let player = playerLayer?.player else { return }
        if player.playbackVolume != level { player.playbackVolume = level }
        if player.isMuted != muted { player.isMuted = muted }
    }
}

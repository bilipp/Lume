//
//  FullScreenPlayerView+Adoption.swift
//  Lume
//
//  Full screen taking over the tvOS Guide preview's running stream (see
//  `PreviewPlayerHandle`), so Select on the previewed channel neither opens a
//  second provider connection nor re-resolves a Stalker link.
//

import KSPlayer
import SwiftUI

extension FullScreenPlayerView {
    struct PreviewAdoption {
        let handle: PreviewPlayerHandle
        let mediaID: String
        /// Index of the adopted engine in the player's priority list.
        let engineAttempt: Int
        let resolvedMedia: PlayableMedia?
        let coordinator: PreviewPlayerHandle.EngineCoordinator
    }

    /// `nil` unless the Guide claimed `handle` for full screen while it held a
    /// started session of `media` on an engine full screen can adopt.
    static func previewAdoption(
        of handle: PreviewPlayerHandle?,
        for media: PlayableMedia,
        enginePriority: [PlayerEngineKind],
        airPlayActive: Bool
    ) -> PreviewAdoption? {
        guard let handle, handle.owner == .fullScreen, let coordinator = handle.coordinator,
              PreviewPlayerHandle.canAdopt(
                  engine: coordinator.engine,
                  hasStarted: handle.hasStarted,
                  previewMediaID: handle.media?.id,
                  selectedMediaID: media.id,
                  airPlayActive: airPlayActive
              ),
              let attempt = enginePriority.firstIndex(of: coordinator.engine)
        else { return nil }
        return PreviewAdoption(
            handle: handle,
            mediaID: media.id,
            engineAttempt: attempt,
            resolvedMedia: handle.resolvedMedia,
            coordinator: coordinator
        )
    }

    /// The preview ran muted; the session switches to `.playback` before its
    /// sound comes up. Synchronous, from `onAppear`, so it lands before the
    /// first frame full screen shows.
    func beginPreviewAdoption() {
        guard let adoption else { return }
        configureAudioSessionForPlayback()
        adoption.coordinator.setMuted(false)
    }

    /// Only for the attempt that adopted it, on the channel it was adopted
    /// for: a fallback or a later return to that attempt builds its engine
    /// fresh.
    var adoptedKSCoordinator: KSVideoPlayer.Coordinator? {
        isAdoptedAttempt ? adoption?.coordinator.ksCoordinator : nil
    }

    /// Flagged before `AVPlayerVideoContainer` mounts: `attach(layer:)` only
    /// wires Picture in Picture and AirPlay for a coordinator that isn't
    /// embedded.
    func takeOverAdoptedAVCoordinator() -> AVPlayerCoordinator? {
        guard isAdoptedAttempt, let coordinator = adoption?.coordinator.avCoordinator else { return nil }
        coordinator.isEmbedded = false
        coordinator.isAdoptedFromPreview = true
        return coordinator
    }

    private var isAdoptedAttempt: Bool {
        guard let adoption else { return false }
        return adoption.engineAttempt == engineAttempt && adoption.mediaID == activeMedia.id
    }

    /// The adopted session is already playing the preview's resolved Stalker
    /// link; resolving again would spend a `create_link` and swap the URL
    /// under it.
    var keepsAdoptedResolution: Bool {
        guard let seeded = adoption?.resolvedMedia else { return false }
        return seeded.id == activeMedia.id && resolvedMedia == seeded
    }
}

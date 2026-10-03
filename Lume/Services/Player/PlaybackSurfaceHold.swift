//
//  PlaybackSurfaceHold.swift
//  Lume
//
//  A playback surface other than the full-screen player — Multi-View, the
//  tvOS Guide preview — runs through the shared engine coordinators, so QoE
//  would score it as a full-screen session, and the indexer's saves would
//  hitch it like any other playback. The surface holds both while it plays.
//

enum PlaybackSurfaceHold {
    static func set(_ holds: Bool, owner: String) {
        if holds {
            PlaybackQoE.shared.suspend(for: owner)
            ContentIndexingService.shared.suspend(for: owner)
        } else {
            PlaybackQoE.shared.resume(for: owner)
            ContentIndexingService.shared.resume(for: owner)
        }
    }
}

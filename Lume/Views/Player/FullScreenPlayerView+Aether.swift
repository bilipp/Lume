//
//  FullScreenPlayerView+Aether.swift
//  Lume
//
//  The AetherEngine branch of `engineView(for:)`. visionOS never links the
//  engine and never offers it, so a stray attempt there moves straight on.
//

import SwiftUI

extension FullScreenPlayerView {
    @ViewBuilder
    func aetherEngineView(
        for media: PlayableMedia,
        skipSegments: IntroSegments?,
        onPlaybackFailed: @escaping () -> Void
    ) -> some View {
        #if os(visionOS)
            UnavailableEngineStub(onUnavailable: onPlaybackFailed)
                .id(engineAttempt)
        #else
            AetherEngineEngineView(
                media: media, clock: clock, mediaSwapper: mediaSwapper,
                nextUpMedia: nextUpMedia, itemNeighbours: itemNeighbours,
                skipSegments: skipSegments,
                reportsStartupFailure: reportsStartupFailure,
                usesQuickStartupTimeout: hasFallbackEngine,
                onPlaybackFailed: onPlaybackFailed,
                onSelectMedia: switchMedia,
                onCompleteCurrentItem: completeActiveEpisode, onRemoteAdvance: remoteAdvanceHandler, refreshStreamURL: stalkerURLRefresh
            )
            .id(engineAttempt)
        #endif
    }
}

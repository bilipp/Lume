//
//  KSPlayerEngineView+Adoption.swift
//  Lume
//
//  Full screen taking over the tvOS Guide preview's running KSPlayer session
//  (see `PreviewPlayerHandle`) instead of opening a second provider connection.
//

import KSPlayer
import SwiftUI

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
extension KSPlayerEngineView {
    /// An adopted session renders through `KSHostedPlayerSurface`; both paths
    /// get the view from `Coordinator.makeView`, which leaves a session already
    /// playing this URL untouched — never `layer.prepareToPlay()` on it.
    @ViewBuilder
    func videoSurface(
        options: KSOptions,
        onStateChanged: @escaping (KSPlayerLayer, KSPlayerState) -> Void,
        onPlay: @escaping (TimeInterval, TimeInterval) -> Void
    ) -> some View {
        #if os(tvOS)
            if isAdoptedSession {
                KSHostedPlayerSurface(
                    coordinator: coordinator,
                    url: media.url,
                    options: options,
                    mode: .adopted,
                    onStateChanged: onStateChanged,
                    onPlay: onPlay
                )
            } else {
                videoPlayer(options: options, onStateChanged: onStateChanged, onPlay: onPlay)
            }
        #else
            videoPlayer(options: options, onStateChanged: onStateChanged, onPlay: onPlay)
        #endif
    }

    private func videoPlayer(
        options: KSOptions,
        onStateChanged: @escaping (KSPlayerLayer, KSPlayerState) -> Void,
        onPlay: @escaping (TimeInterval, TimeInterval) -> Void
    ) -> some View {
        KSVideoPlayer(coordinator: coordinator, url: media.url, options: options)
            .onStateChanged(onStateChanged)
            .onPlay(onPlay)
    }

    /// The adopted session already passed `.readyToPlay` before this view
    /// existed, so that callback will never arrive; seed the gates it opens
    /// from the layer's current state instead. Call after the startup watchdog
    /// is armed, so a session caught mid-rebuffer still has one.
    func seedAdoptedSessionState() {
        #if os(tvOS)
            guard isAdoptedSession else { return }
            hasSeenReadyToPlay = true
            let state = coordinator.state
            isPlaying = state == .bufferFinished
            updateLoadingState(state)
            engine.syncState(state)
        #endif
    }
}

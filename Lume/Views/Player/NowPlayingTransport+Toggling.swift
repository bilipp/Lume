//
//  NowPlayingTransport+Toggling.swift
//  Lume
//
//  The remote-command transport for engines whose coordinator exposes a single
//  play/pause toggle.
//

import SwiftUI

/// A coordinator that drives playback through one toggle.
protocol TogglePlaybackControlling: AnyObject {
    var isPlaying: Bool { get }
    func togglePlay()
    func seek(to seconds: TimeInterval)
}

extension NowPlayingService.Transport {
    /// Play and pause map onto the coordinator's toggle, each a no-op when the
    /// coordinator is already in that state.
    static func toggling(
        _ coordinator: some TogglePlaybackControlling,
        advance: ((PlayerMediaSwapper.Step) -> Bool)?
    ) -> Self {
        .init(
            isPlaying: { [weak coordinator] in coordinator?.isPlaying ?? false },
            play: { [weak coordinator] in
                guard let coordinator, !coordinator.isPlaying else { return }
                coordinator.togglePlay()
            },
            pause: { [weak coordinator] in
                guard let coordinator, coordinator.isPlaying else { return }
                coordinator.togglePlay()
            },
            seek: { [weak coordinator] in coordinator?.seek(to: $0) },
            advance: advance
        )
    }
}

extension View {
    /// Hands the coordinator's transport to `NowPlayingService` while this
    /// view is on screen, so lock-screen / remote commands drive the engine
    /// Lume owns rather than any session the engine could publish itself.
    func nowPlayingTransport(
        _ coordinator: some TogglePlaybackControlling,
        advance: ((PlayerMediaSwapper.Step) -> Bool)?
    ) -> some View {
        onAppear {
            NowPlayingService.shared.attachTransport(.toggling(coordinator, advance: advance), owner: coordinator)
        }
        .onDisappear {
            NowPlayingService.shared.detachTransport(owner: coordinator)
        }
    }
}

extension AVPlayerCoordinator: TogglePlaybackControlling {}
extension VLCPlayerCoordinator: TogglePlaybackControlling {}
extension LumeEngineCoordinator: TogglePlaybackControlling {}
#if !os(visionOS)
    extension AetherEngineCoordinator: TogglePlaybackControlling {}
#endif

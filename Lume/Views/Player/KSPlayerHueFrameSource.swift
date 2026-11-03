//
//  KSPlayerHueFrameSource.swift
//  Lume
//
//  Hue frames from KSPlayer, whichever of its two players runs the stream:
//  KSMEPlayer hands out the pixel buffer it just drew, KSAVPlayer gets an
//  `AVPlayerItemVideoOutput` on its current item while sync is on.
//

#if os(tvOS)
    import Foundation
    import KSPlayer

    final class KSPlayerHueFrameSource: HueFrameSource {
        private weak var coordinator: KSVideoPlayer.Coordinator?
        private var itemTap: HuePlayerItemTap?
        var contentCheck: (key: StreamKey, reason: HueFrameUnavailableReason?)?

        struct StreamKey: Equatable {
            var player: ObjectIdentifier
            var url: URL
        }

        init(coordinator: KSVideoPlayer.Coordinator) {
            self.coordinator = coordinator
        }

        func latestFrame() -> HueFrameSample {
            guard let playerLayer = coordinator?.playerLayer else {
                detach()
                return .noFrame
            }
            let player = playerLayer.player
            if let player = player as? KSAVPlayer {
                let tap = itemTap ?? HuePlayerItemTap()
                itemTap = tap
                return tap.latestFrame(of: player.player)
            }
            detach()
            if let player = player as? KSMEPlayer {
                return latestFrame(of: player, url: playerLayer.url)
            }
            return .unavailable(.unsupportedEngine)
        }

        func detach() {
            itemTap?.detach()
            itemTap = nil
        }
    }
#endif

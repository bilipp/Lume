//
//  KSPlayerEngineView+ZapFrame.swift
//  Lume
//
//  Holds the outgoing channel's last frame on screen while the next one
//  starts, the way a TV freezes on a zap, instead of a second or more of
//  black: swapping the URL stops the running stream before the new one has
//  decoded anything.
//

import CoreGraphics
import KSPlayer
import SwiftUI

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
extension KSPlayerEngineView {
    /// How long a held frame may stay up if the next stream never reports
    /// its first frame (the failure paths clear it sooner).
    private static let zapFrameTimeout: Duration = .seconds(10)

    /// Hands the next media to the host, first capturing the frame on screen.
    /// Every in-player swap goes through here: channel surfing, the channel
    /// browser, the transport controls and the episode overlays.
    func selectMedia(_ next: PlayableMedia) {
        guard let onSelectMedia else { return }
        // Only a playing KSMEPlayer: its capture just converts the current
        // pixel buffer, where KSAVPlayer's would decode a frame from the
        // asset and hold up the switch.
        guard next.id != media.id, hasStartedPlayback,
              let player = coordinator.playerLayer?.player as? KSMEPlayer
        else {
            onSelectMedia(next)
            return
        }
        Task { @MainActor in
            await holdZapFrame(player.thumbnailImageAtCurrentTime())
            onSelectMedia(next)
        }
    }

    /// Drops the held frame: the new stream is playing (`fading`, so the old
    /// picture dissolves into the new one), failed, or never started.
    func releaseZapFrame(fading: Bool = false) {
        guard zapFrame != nil else { return }
        withAnimation(fading ? .easeOut(duration: 0.25) : nil) {
            zapFrame = nil
        }
    }

    private func holdZapFrame(_ frame: CGImage?) {
        zapFrame = frame
        zapFrameToken &+= 1
        let token = zapFrameToken
        Task { @MainActor in
            try? await Task.sleep(for: Self.zapFrameTimeout)
            if zapFrameToken == token {
                releaseZapFrame()
            }
        }
    }

    /// Above the video and below the subtitles, spinner and controls, which
    /// keep showing that the next channel is on its way.
    @ViewBuilder
    var zapFrameOverlay: some View {
        if let zapFrame {
            Image(decorative: zapFrame, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }
}

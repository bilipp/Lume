//
//  GuideHeroModel.swift
//  Lume
//
//  What the tvOS Guide hero and the Live TV backdrop describe: the row focus
//  is on and the settled channel's glow. A reference beside
//  `GuidePreviewController`, read only by the hero's info block, its
//  placeholder card and the backdrop, so a press never re-renders the grid.
//

import SwiftUI

@MainActor @Observable
final class GuideHeroModel {
    /// The guide row tvOS focus is on, `nil` while focus is outside the
    /// guide. Written by the scroller and read only by the hero's info block.
    var focusedRow: EPGChannelRow?
    /// The settled channel's logo colour, or the accent.
    private(set) var glowTint: Color = LiveTVPalette.accent

    @ObservationIgnored private var glowLogo: String?
    @ObservationIgnored private var glowTask: Task<Void, Never>?

    /// Tints the glow from the logo of the channel the preview settled on.
    func settleGlow(onLogo logo: URL?) {
        let key = logo?.absoluteString
        guard key != glowLogo else { return }
        glowLogo = key
        glowTask?.cancel()
        glowTask = Task { [weak self] in
            let hex = await ChannelLogoTintCache.shared.tint(forLogo: key)
            guard !Task.isCancelled, let self else { return }
            let color = LiveTVPalette.glowColor(forTintHex: hex)
            guard color != glowTint else { return }
            // A plain write: wrapped in `withAnimation` from this task, the
            // backdrop missed the change until something else re-rendered it.
            // The backdrop animates the crossfade itself.
            glowTint = color
        }
    }
}

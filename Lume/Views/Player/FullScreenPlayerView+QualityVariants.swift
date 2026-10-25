//
//  FullScreenPlayerView+QualityVariants.swift
//  Lume
//
//  The player host's half of the live Quality menu: it resolves the other
//  qualities the playlist lists the playing channel in, once per stream, and
//  hands them to the engine overlays together with what picking one does.
//

import SwiftData
import SwiftUI

/// The playing live channel's quality variants and what picking one does, for
/// the overlays' Quality control.
struct PlayerQualitySwitcher {
    /// Current one included; empty when there is nothing to switch to.
    let variants: [LiveQualityVariantOption]
    /// The `LiveStream.id` on screen, which marks the current row of `variants`.
    let currentID: String?
    let select: (LiveQualityVariantOption) -> Void

    /// `LiveQualityVariants` resolves either no variants or at least two.
    var offersSwitching: Bool {
        !variants.isEmpty
    }
}

extension EnvironmentValues {
    /// `nil` outside the full-screen player.
    @Entry var playerQualitySwitcher: PlayerQualitySwitcher?
}

extension FullScreenPlayerView {
    /// Plays another quality of the channel on screen. Not a channel change:
    /// the Recall pair and Recently Watched stay on the channel the viewer
    /// tuned to, and up/down keeps surfing from its position.
    func switchQuality(to option: LiveQualityVariantOption) {
        guard case let .live(playingID) = activeMedia.contentRef, option.id != playingID else { return }
        mediaSwapper.swap { switchMedia(to: option.target) }
    }
}

/// Resolves the active channel's quality variants off the main actor and
/// injects them, with `onSelect`, for the engine overlays.
struct PlayerQualityVariantsHost: ViewModifier {
    let media: PlayableMedia
    let onSelect: (LiveQualityVariantOption) -> Void

    @Environment(\.contentRestriction) private var contentRestriction
    @Environment(\.modelContext) private var modelContext
    @AppStorage(PlayerSettings.Playback.liveQualitySwitchKey)
    private var isEnabled = PlayerSettings.Playback.liveQualitySwitchDefault
    @State private var variants: [LiveQualityVariantOption] = []

    private struct ResolveKey: Equatable {
        let mediaID: String
        let isEnabled: Bool
    }

    private var playingID: String? {
        if case let .live(id) = media.contentRef { id } else { nil }
    }

    func body(content: Content) -> some View {
        content
            .environment(
                \.playerQualitySwitcher,
                PlayerQualitySwitcher(variants: variants, currentID: playingID, select: onSelect)
            )
            .task(id: ResolveKey(mediaID: media.id, isEnabled: isEnabled), priority: .utility) {
                guard isEnabled else {
                    variants = []
                    return
                }
                // A switch between the listed qualities keeps the menu on
                // screen (and focused on tvOS) while the list re-resolves.
                if !variants.contains(where: { $0.id == playingID }) {
                    variants = []
                }
                // Lets the stream start first; a zap past this channel
                // cancels the scan before it runs.
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                let resolved = await LiveQualityVariants.resolve(
                    for: media, restriction: contentRestriction, container: modelContext.container
                )
                if !Task.isCancelled { variants = resolved }
            }
    }
}

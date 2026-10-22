//
//  TVPlayerControlsOverlay+Quality.swift
//  Lume
//
//  The tvOS player's Quality menu, in the trailing row between Sources and
//  Favorite, for a live channel the playlist also lists in another quality.
//  It reads the variants the host resolves (`PlayerQualityVariantsHost`), the
//  same ones the other platforms' `PlayerQualityButton` shows.
//

#if os(tvOS)

    import SwiftUI

    extension TVPlayerControlsOverlay {
        var qualityButton: some View {
            TVPlayerQualityButton(focus: $focus, onResetHideTimer: onResetHideTimer)
        }
    }

    extension View {
        /// Hands focus on when the Quality menu leaves the row while it holds
        /// focus — surfing to a channel with a single quality removes it, and a
        /// focused view that vanishes leaves focus orphaned. Attached to the
        /// trailing row, which outlives the menu.
        func tvPlayerQualityFocusHandoff(
            media: PlayableMedia,
            focus: FocusState<TVPlayerFocus?>.Binding
        ) -> some View {
            modifier(TVPlayerQualityFocusHandoff(media: media, focus: focus))
        }
    }

    private struct TVPlayerQualityFocusHandoff: ViewModifier {
        let media: PlayableMedia
        var focus: FocusState<TVPlayerFocus?>.Binding

        @Environment(\.playerQualitySwitcher) private var switcher

        func body(content: Content) -> some View {
            content
                .tvPlayerFocusHandoff(
                    isShown: switcher?.offersSwitching == true,
                    leaving: .quality,
                    to: PlayerFavorites.supportsFavorites(media.contentRef) ? .favorite : .transport,
                    focus: focus
                )
        }
    }

    private struct TVPlayerQualityButton: View {
        var focus: FocusState<TVPlayerFocus?>.Binding
        var onResetHideTimer: () -> Void

        @Environment(\.playerQualitySwitcher) private var switcher

        var body: some View {
            if let switcher, switcher.offersSwitching {
                Menu {
                    PlayerQualityMenuItems(switcher: switcher, onResetHideTimer: onResetHideTimer)
                } label: {
                    Image(systemName: "sparkles.tv")
                }
                .menuIndicator(.hidden)
                .buttonStyle(TVPlayerCircleButtonStyle())
                .focused(focus, equals: .quality)
                .trackMenuAccessibility(
                    "Quality", selected: switcher.variants.first { $0.id == switcher.currentID }?.tag, fallback: "Standard"
                )
            }
        }
    }

#endif

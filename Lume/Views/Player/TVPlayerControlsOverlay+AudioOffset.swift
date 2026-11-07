//
//  TVPlayerControlsOverlay+AudioOffset.swift
//  Lume
//
//  The tvOS player's Audio Delay menu, in the trailing row after Quality,
//  while the engine on screen can shift its audio while playing. It reads
//  the session the host owns (`PlayerAudioOffsetHost`), the same one the
//  other platforms' `PlayerAudioOffsetButton` shows.
//

#if os(tvOS)

    import SwiftUI

    extension TVPlayerControlsOverlay {
        var audioOffsetButton: some View {
            TVPlayerAudioOffsetButton(focus: $focus, onResetHideTimer: onResetHideTimer)
        }
    }

    extension View {
        /// Hands focus on when the Audio Delay menu leaves the row while it
        /// holds focus: an engine fallback to AVPlayer removes it, and a
        /// focused view that vanishes leaves focus orphaned. Attached to the
        /// trailing row, which outlives the menu.
        func tvPlayerAudioOffsetFocusHandoff(
            media: PlayableMedia,
            focus: FocusState<TVPlayerFocus?>.Binding
        ) -> some View {
            modifier(TVPlayerAudioOffsetFocusHandoff(media: media, focus: focus))
        }
    }

    private struct TVPlayerAudioOffsetFocusHandoff: ViewModifier {
        let media: PlayableMedia
        var focus: FocusState<TVPlayerFocus?>.Binding

        @Environment(\.playerAudioOffset) private var session

        func body(content: Content) -> some View {
            content
                .tvPlayerFocusHandoff(
                    isShown: session?.isAdjustable == true,
                    leaving: .audioOffset,
                    to: PlayerFavorites.supportsFavorites(media.contentRef) ? .favorite : .transport,
                    focus: focus
                )
        }
    }

    private struct TVPlayerAudioOffsetButton: View {
        var focus: FocusState<TVPlayerFocus?>.Binding
        var onResetHideTimer: () -> Void

        @Environment(\.playerAudioOffset) private var session

        var body: some View {
            if let session, session.isAdjustable {
                Menu {
                    PlayerAudioOffsetMenuItems(session: session, onResetHideTimer: onResetHideTimer)
                } label: {
                    Image(systemName: session.effectiveMilliseconds == 0 ? "metronome" : "metronome.fill")
                }
                .menuIndicator(.hidden)
                .buttonStyle(TVPlayerCircleButtonStyle())
                .focused(focus, equals: .audioOffset)
                .trackMenuAccessibility(
                    "Audio Delay", selected: AudioOffsetPreset.label(session.effectiveMilliseconds), fallback: "Default"
                )
            }
        }
    }

#endif

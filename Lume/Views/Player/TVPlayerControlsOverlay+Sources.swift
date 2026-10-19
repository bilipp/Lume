//
//  TVPlayerControlsOverlay+Sources.swift
//  Lume
//
//  The tvOS player's Sources control, in the trailing row between the track
//  menus and Favorite, for a Jellyfin/Emby title with more than one version.
//  It shares the host's `PlayerSourceSession` with the other platforms'
//  `PlayerSourcesButton`. Its presence is settled before the engine mounts —
//  the versions are listed first — so it never leaves the row under focus.
//

#if os(tvOS)

    import SwiftUI

    extension TVPlayerControlsOverlay {
        var sourcesButton: some View {
            TVPlayerSourcesButton(focus: $focus, onResetHideTimer: onResetHideTimer)
        }
    }

    private struct TVPlayerSourcesButton: View {
        var focus: FocusState<TVPlayerFocus?>.Binding
        var onResetHideTimer: () -> Void

        @Environment(\.playerSourceSession) private var session

        var body: some View {
            if let session, session.offersSwitching {
                Button {
                    session.isPresentingSwitcher = true
                    onResetHideTimer()
                } label: {
                    Image(systemName: "rectangle.stack")
                }
                .buttonStyle(TVPlayerCircleButtonStyle())
                .focused(focus, equals: .sources)
                .accessibilityLabel("Sources")
            }
        }
    }

#endif

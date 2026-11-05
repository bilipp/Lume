//
//  FullScreenPlayerView+AudioOffset.swift
//  Lume
//
//  Hands the player's audio-offset session to the engine views and overlays,
//  and keeps it on the stream the host makes active.
//

import SwiftUI

/// Attached to the player tree next to the Sources and Quality hosts.
/// Injects the session for `PlayerAudioOffsetButton` (iOS, macOS,
/// visionOS), its tvOS counterpart and the engine views, and refreshes the
/// provider default whenever the active stream changes.
struct PlayerAudioOffsetHost: ViewModifier {
    let session: PlayerAudioOffsetSession
    let media: PlayableMedia

    func body(content: Content) -> some View {
        content
            .environment(\.playerAudioOffset, session)
            .onChange(of: media.id, initial: true) { _, _ in
                session.update(for: media)
            }
    }
}

//
//  SportsPlayback.swift
//  Lume
//
//  Shared playback routing for the Sports Hub. Every fixture "Watch" action —
//  across the phone and tvOS home rails, the league screen and both hub screens —
//  resolves a tapped `ResolvedChannel` to a `PlayableMedia` the same way: find the
//  live stream in the viewer's own playlists, find its owning playlist, then build
//  the media. Presentation (the after-sheet delay, the macOS player window) stays
//  with each view, since it mutates that view's own state.
//

import SwiftData
import SwiftUI

enum SportsPlayback {
    /// The playable live stream a tapped channel points at, or `nil` when it is no
    /// longer present in the viewer's playlists.
    static func media(for channel: ResolvedChannel, in context: ModelContext) -> PlayableMedia? {
        guard let stream = PlayerContentLookup.liveStream(channel.stream.id, in: context),
              let playlist = LiveChannelNavigator.playlist(for: stream, in: context)
        else { return nil }
        return PlayableMedia.from(stream: stream, playlist: playlist)
    }
}

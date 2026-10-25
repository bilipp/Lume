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

/// The game card a Watch press came from, kept while the player is up so that
/// closing it lands back on that card rather than on the hub — trying a game's
/// sources one by one otherwise means finding the game again after every miss.
struct SportsWatchReturn {
    /// Which of the presenter's two fixture sheets started playback.
    enum Card {
        case detail
        case picker
    }

    let fixture: SportsFixture
    let card: Card
    let channelID: String

    /// The fixture as the store has it now, so a game that ended while the
    /// player was up reopens as ended; the copy taken at the press otherwise.
    func currentFixture(in store: SportsStore) -> SportsFixture {
        store.snapshot(for: fixture.leagueId)?.fixtures.first { $0.id == fixture.id } ?? fixture
    }

    /// The channel to mark on the reopened card: the one on screen when the
    /// player closed, when the viewer surfed onto another of this game's
    /// channels, else the one the card launched.
    func channelToMark(
        among channels: [ResolvedChannel],
        playing: String? = LiveChannelHistory.currentChannelId()
    ) -> String {
        if let playing, channels.contains(where: { $0.id == playing }) {
            return playing
        }
        return channelID
    }
}

extension SportsWatchReturn {
    /// The return for a Watch pressed on whichever of the two sheets is up, or
    /// `nil` when playback started straight from a card.
    init?(channel: ResolvedChannel, detail: SportsFixture?, picker: SportsFixture?) {
        if let detail {
            self.init(fixture: detail, card: .detail, channelID: channel.id)
        } else if let picker {
            self.init(fixture: picker, card: .picker, channelID: channel.id)
        } else {
            return nil
        }
    }
}

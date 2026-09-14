//
//  PlayerItemNavigation.swift
//  Lume
//
//  Resolves what the in-player previous/next transport buttons play, for both
//  axes the player offers: the episodes of a series and the channels of a live
//  list. Pure, cross-platform data resolution — no view state — so the hosts
//  can resolve once per stream and the result unit-tests without a host.
//
//  The two axes already have resolvers of their own (`NextEpisodeResolver`,
//  `LiveChannelNavigator`); this picks the right one for a stream, applies the
//  rules that belong to the *buttons* rather than to either resolver, and hands
//  back a single answer the overlays can render from.
//

import Foundation
import SwiftData

enum PlayerItemNavigation {
    /// Which pair of transport controls a stream offers.
    nonisolated enum Axis: Equatable {
        /// Previous/next episode, ordered across the whole series.
        case episode
        /// Previous/next channel, one position along the list playback started
        /// from.
        case channel
    }

    /// What the previous/next buttons should do for one stream.
    ///
    /// `neighboursUnknown` separates "there is no neighbour" from "we can't tell
    /// yet": an Xtream or Stalker series carries no `Episode` rows until a
    /// detail screen fetches them, so a stream launched from Continue Watching
    /// or a `lume://` link can have neighbours the catalog simply doesn't know
    /// about. The buttons render disabled in that case rather than vanishing,
    /// which would move the rest of the transport row out from under the
    /// viewer's finger.
    struct Neighbours: Equatable {
        var axis: Axis?
        var previous: PlayableMedia?
        var next: PlayableMedia?
        var neighboursUnknown = false

        /// No transport pair at all — a movie, or a stream whose axis is
        /// deliberately suppressed.
        static let none = Neighbours()

        /// How one end of the transport pair renders for this stream.
        ///
        /// `neighboursUnknown` outranks the resolved neighbour on purpose: a
        /// stale catalog can only have answered "nothing that way" by not
        /// knowing, so the press must not be offered even if a neighbour is
        /// carried alongside the flag.
        func buttonState(for step: PlayerMediaSwapper.Step) -> ButtonState {
            guard axis != nil else { return .hidden }
            if neighboursUnknown { return .disabled }
            return (step == .next ? next : previous) == nil ? .disabled : .enabled
        }
    }

    /// What a transport button does with a resolved `Neighbours`.
    ///
    /// `.disabled` and `.hidden` are deliberately different answers: a series
    /// the catalog has no episodes for yet, and a list edge, keep the button in
    /// place so the row doesn't slide out from under the viewer's finger, while
    /// a stream with no axis at all never had a pair to begin with.
    enum ButtonState: Equatable {
        case hidden
        case disabled
        case enabled
    }

    /// The previous and next stream for `media`, resolved once per stream by the
    /// player host.
    ///
    /// `restriction` is required rather than defaulted, like
    /// `LiveChannelNavigator.adjacentMedia`: a permissive default here would let
    /// a child profile step out of the catalog a parent locked.
    static func neighbours(
        for media: PlayableMedia,
        sort: ContentSortOption,
        restriction: ContentRestriction,
        in context: ModelContext,
        client: XtreamClient = XtreamClient()
    ) -> Neighbours {
        switch axis(for: media) {
        case .episode:
            episodeNeighbours(for: media.contentRef, in: context, client: client)
        case .channel:
            channelNeighbours(for: media, sort: sort, restriction: restriction, in: context)
        case nil:
            .none
        }
    }

    /// Which way, if either, `media` can be stepped — decided from the stream
    /// alone, without touching the catalog.
    ///
    /// Separate from `neighbours` because the lock screen needs the answer
    /// before it has one: `MPRemoteCommandCenter` enables or greys out
    /// next/previous track per stream, and a SwiftData fetch is the wrong price
    /// for that. It also states the catch-up rule once for both callers.
    nonisolated static func axis(for media: PlayableMedia) -> Axis? {
        switch media.contentRef {
        case .episode:
            .episode
        case .live:
            // Catch-up plays a recording of a channel as on-demand video.
            // Surfing would drop the viewer out of the recording and into live
            // TV, so the channel axis is suppressed for it — the kind, not the
            // ref, is what separates the two.
            if case .live = media.kind { .channel } else { nil }
        case .movie:
            nil
        }
    }

    /// Episode neighbours across the whole series, so a season finale advances
    /// into the next season's premiere. The bounded lookup of the playing
    /// episode is what tells a stale catalog (no rows yet) apart from a genuine
    /// series premiere or finale; no episodes are fetched from the provider to
    /// find out, mid-playback round trips being exactly what a one-connection
    /// portal can't spare.
    ///
    /// Reachable on its own for the tvOS transport row, which drives channel
    /// surfing from the remote and so has no live sort to hand `neighbours` —
    /// it needs this axis and no other.
    static func episodeNeighbours(
        for ref: PlayableMedia.ContentRef,
        in context: ModelContext,
        client: XtreamClient = XtreamClient()
    ) -> Neighbours {
        guard case let .episode(id) = ref else { return .none }

        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let current = try? context.fetch(descriptor).first, current.series != nil else {
            return Neighbours(axis: .episode, neighboursUnknown: true)
        }

        return Neighbours(
            axis: .episode,
            previous: NextEpisodeResolver.previousMedia(before: ref, in: context, client: client),
            next: NextEpisodeResolver.nextMedia(after: ref, in: context, client: client)
        )
    }

    /// Channel neighbours one position along the list `media` was launched from,
    /// carried on `media.channelScope`.
    ///
    /// Always the raw `±1` offset, never the `surfing:mode:` overload: that one
    /// applies the viewer's `LiveSurfMode`, which maps a remote's up/down keys
    /// and would run a button labelled "next" backwards under `.listOrder`.
    ///
    /// Only reached for a stream `axis(for:)` has already put on this axis.
    private static func channelNeighbours(
        for media: PlayableMedia,
        sort: ContentSortOption,
        restriction: ContentRestriction,
        in context: ModelContext
    ) -> Neighbours {
        Neighbours(
            axis: .channel,
            previous: LiveChannelNavigator.adjacentMedia(
                for: media, offset: -1, sort: sort, restriction: restriction, in: context
            ),
            next: LiveChannelNavigator.adjacentMedia(
                for: media, offset: 1, sort: sort, restriction: restriction, in: context
            )
        )
    }
}

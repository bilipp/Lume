//
//  LiveChannelNavigator.swift
//  Lume
//
//  Resolves the channel to surf to when the viewer asks for the next/previous
//  live stream from inside the player (the tvOS player drives this from up/down
//  on the Siri Remote). Kept as pure, cross-platform data resolution — no view
//  state — so it can be unit-tested independently of any UI.
//

import Foundation
import SwiftData

// Two channel-resolution helpers take six parameters: the media, the ordering
// its list is in, the profile's restriction and the context are each needed to
// resolve a single channel, and bundling them would only hide the inputs.
// swiftlint:disable function_parameter_count

/// How an up or down press on the remote maps onto the live channel list while
/// a channel is playing. Both modes walk the same list — whichever the channel
/// was launched from, in the sort the viewer had active — so this only decides
/// which way each press moves along it.
///
/// Note what neither mode does: read channel numbers. `channelUpDown` lines up
/// with the lineup's numbering only while the list is in playlist order, which
/// is why the alternative exists at all — under a name sort, or in Favorites,
/// "next channel" is just the row below and up reads as inverted.
enum LiveSurfMode: String, CaseIterable, Identifiable {
    /// Up moves to the next channel in the list, down to the previous — a TV
    /// remote's channel rocker.
    case channelUpDown = "channel"
    /// Up moves to the row above in the channel list, down to the row below —
    /// the way every other up/down handler in the app moves.
    case listOrder = "list"

    /// The channel rocker, which is how in-player surfing has always behaved.
    static let `default` = LiveSurfMode.channelUpDown

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .channelUpDown: String(localized: "Channel Up/Down")
        case .listOrder: String(localized: "List Order")
        }
    }

    /// The stored preference, falling back to the rocker for anything the
    /// picker didn't write — including the unset default. Read off
    /// `UserDefaults` directly, like `PlayerSettings.Playback`'s accessors: the
    /// player hosts want this at the moment of a key press, and an `@AppStorage`
    /// would re-render the whole player tree whenever it changed.
    static var preferred: LiveSurfMode {
        resolve(UserDefaults.standard.string(forKey: PlayerSettings.liveSurfModeKey))
    }

    /// The mode `raw` names, or the default when it names none. Split out from
    /// `preferred` for the settings picker, which holds the raw value in
    /// `@AppStorage` and needs the same fallback to label the row.
    static func resolve(_ raw: String?) -> LiveSurfMode {
        guard let raw, let mode = LiveSurfMode(rawValue: raw) else { return .default }
        return mode
    }
}

enum LiveChannelNavigator {
    /// The playlist that owns a live stream. Stream `id`s are prefixed with the
    /// owning playlist's UUID at sync time (see `ContentSyncManager`).
    static func playlist(for stream: LiveStream, in context: ModelContext) -> Playlist? {
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        return playlists.first { stream.id.hasPrefix($0.id.uuidString) } ?? playlists.first
    }

    /// Which way the viewer asked to surf. The remote presses a direction, not
    /// an index, so this is what the player hands over: turning it into an
    /// offset is this file's job, next to the ordering that offset indexes
    /// into. Four engine hosts each used to do that arithmetic themselves,
    /// which is why the direction is resolved in one place now.
    enum SurfDirection {
        // `up` is two characters: the cases are named for the keys, mirroring
        // the `MoveCommandDirection` the hosts translate from.
        // swiftlint:disable identifier_name
        /// The remote's up press.
        case up
        /// The remote's down press.
        case down
        // swiftlint:enable identifier_name

        /// The list offset this press means under `mode`. The two modes are
        /// mirror images — the list is walked either way, only the sign
        /// differs — which is exactly why the choice belongs to the viewer
        /// rather than to whichever host handled the press.
        fileprivate func offset(in mode: LiveSurfMode) -> Int {
            switch (mode, self) {
            case (.channelUpDown, .up), (.listOrder, .down): 1
            case (.channelUpDown, .down), (.listOrder, .up): -1
            }
        }
    }

    /// The channel one press of `direction` away, within the list `media` was
    /// launched from, mapped onto that list by `mode` — see `LiveSurfMode`.
    /// See `adjacentMedia(for:offset:sort:restriction:in:)` for how the list
    /// itself is resolved.
    static func adjacentMedia(
        for media: PlayableMedia,
        surfing direction: SurfDirection,
        mode: LiveSurfMode,
        sort: ContentSortOption,
        restriction: ContentRestriction,
        in context: ModelContext
    ) -> PlayableMedia? {
        adjacentMedia(for: media, offset: direction.offset(in: mode), sort: sort, restriction: restriction, in: context)
    }

    /// The playable channel `offset` positions away from `media` within the list
    /// it was launched from — Favorites, Recently Watched or a category, carried
    /// on `media.channelScope` — honouring `sort` so the order matches the
    /// channel list the viewer browsed. `offset` is `+1` for the next channel
    /// and `-1` for the previous; the list wraps at its ends so surfing never
    /// dead-ends. Returns `nil` when `media` isn't a resolvable live stream or
    /// its list holds a single reachable channel — including when the playing
    /// channel's own category is hidden or locked, which leaves it no position
    /// in any rotation and stops surfing where it stands.
    ///
    /// `restriction` is required rather than defaulted, like the channel-list
    /// helpers it shares descriptors with: surfing is the last surface that
    /// resolved channels on its own, which let a child keep rocking through a
    /// category a parent had locked once playback had started.
    static func adjacentMedia(
        for media: PlayableMedia,
        offset: Int,
        sort: ContentSortOption,
        restriction: ContentRestriction,
        in context: ModelContext
    ) -> PlayableMedia? {
        guard case let .live(id) = media.contentRef else { return nil }
        var currentDescriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        currentDescriptor.fetchLimit = 1
        guard let current = try? context.fetch(currentDescriptor).first,
              let playlist = playlist(for: current, in: context) else { return nil }

        let streams = surfableChannels(
            around: current,
            media: media,
            sort: sort,
            restriction: restriction,
            playlist: playlist,
            in: context
        )
        guard streams.count > 1,
              let index = streams.firstIndex(where: { $0.id == current.id }) else { return nil }

        let target = streams[(index + offset + streams.count) % streams.count]
        // The scope rides along so the next press surfs the same list.
        return PlayableMedia.from(stream: target, playlist: playlist, scope: media.channelScope)
    }

    /// The list `current` is surfed within: the scope playback started from,
    /// falling back to the channel's own category when there is none or the
    /// channel has since dropped out of it (un-favorited, cleared from Recently
    /// Watched). Always contains `current` when non-empty.
    private static func surfableChannels(
        around current: LiveStream,
        media: PlayableMedia,
        sort: ContentSortOption,
        restriction: ContentRestriction,
        playlist: Playlist,
        in context: ModelContext
    ) -> [LiveStream] {
        let prefix = "\(playlist.id.uuidString)-"
        let ownCategory = current.categoryId.map(LiveChannelScope.category)
        // A category launch scope *is* the channel's own category, and the branch
        // below resolves that list anyway — asking for it here first would fetch
        // it twice to get the same answer.
        if let scope = media.channelScope, scope != ownCategory {
            let scoped = channels(in: scope, sort: sort, playlistPrefix: prefix, restriction: restriction, in: context)
            if scoped.contains(where: { $0.id == current.id }) { return scoped }
        }
        guard let categoryId = current.categoryId else { return [] }
        // A category locked away from this viewer surfs nowhere at all — not the
        // browse list below, and not the hidden-channel fallback either: a channel
        // a child somehow landed on must not become a doorway into the rest of a
        // category a parent locked. One check up front rather than a per-row
        // filter on each query: every row either query can return carries this
        // same category id, so the answer is the same for all of them.
        guard !restriction.hides(categoryID: categoryId) else { return [] }
        let category = channels(
            in: .category(categoryId),
            sort: sort,
            playlistPrefix: prefix,
            restriction: restriction,
            in: context
        )
        if category.contains(where: { $0.id == current.id }) { return category }
        // A hidden channel is in no browse list but can still be playing (recall,
        // a deep link) — surf its category rather than dead-end, with the playing
        // channel itself added back so it has a position in the ring. The *other*
        // hidden channels stay out: hiding a channel takes it out of the rotation.
        let currentId = current.id
        let descriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.categoryId == categoryId && ($0.isHidden == false || $0.id == currentId) },
            sortBy: sort.liveStreamDescriptors
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The channels a scope resolves to, using the very descriptors the browse
    /// screens query with so both surfaces stay in one order.
    private static func channels(
        in scope: LiveChannelScope,
        sort: ContentSortOption,
        playlistPrefix: String,
        restriction: ContentRestriction,
        in context: ModelContext
    ) -> [LiveStream] {
        let fetched = (try? context.fetch(LiveChannelQuery.descriptor(for: scope, sort: sort))) ?? []
        return LiveChannelQuery.scoped(fetched, scope: scope, playlistPrefix: playlistPrefix, restriction: restriction)
    }
}

// swiftlint:enable function_parameter_count

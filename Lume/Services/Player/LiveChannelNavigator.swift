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
    /// How many rows of a tied run are read at a time while the playing channel
    /// is located. A page size, not a cap: a run that ties on every sort key is
    /// read page by page until the playing channel turns up, because stopping at
    /// the first page leaves every channel past it unable to surf at all — a
    /// provider block of identically named channels is exactly where that
    /// happens, and `LiveChannelNavigatorCollationTests` pins it.
    private static let tiePage = 64

    /// The playlist that owns a live stream. Stream `id`s are prefixed with the
    /// owning playlist's UUID at sync time (see `ContentSyncManager`).
    static func playlist(for stream: LiveStream, in context: ModelContext) -> Playlist? {
        PlaylistOwner.playlist(forPrefixedID: stream.id, in: context)
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
    ///
    /// A category or Favorites list is never materialized. It is walked as a
    /// `Ring` — a count and a handful of single-row reads — because a live
    /// category runs to thousands of channels and this resolves on the main
    /// actor, once per stream, for both directions. Recently Watched is the
    /// exception, and `recentsRing(…)` says why.
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

        guard let located = ring(
            around: current,
            media: media,
            sort: sort,
            restriction: restriction,
            playlist: playlist,
            in: context
        ) else { return nil }

        let ring = located.ring
        guard ring.count > 1 else { return nil }
        let position = (located.index + offset + ring.count) % ring.count
        guard let target = ring.row(at: position, in: context) else { return nil }
        // The scope rides along so the next press surfs the same list.
        return PlayableMedia.from(stream: target, playlist: playlist, scope: media.channelScope)
    }

    // MARK: - The ring

    /// One row of a channel list, by position — the only shape in which a list
    /// is ever read here.
    static func positionDescriptor(
        _ scope: FetchDescriptor<LiveStream>, at index: Int, count: Int = 1
    ) -> FetchDescriptor<LiveStream> {
        var descriptor = scope
        descriptor.fetchOffset = index
        descriptor.fetchLimit = count
        return descriptor
    }

    /// The channels a scope resolves to, in the order the browse screens show
    /// them, as a descriptor that is never fetched whole.
    ///
    /// Everything that decides membership is in the predicate rather than
    /// applied to fetched rows — the playlist scope included, which the virtual
    /// collections used to answer by fetching every playlist's favorites and
    /// matching `hasPrefix` in Swift. With rows read one position at a time a
    /// Swift-side filter isn't merely slower, it is wrong: the row at a position
    /// has to be the row the viewer sees at that position.
    ///
    /// `admittingHidden` names the one hidden channel a ring re-admits — see
    /// `ring(around:…)`.
    static func scopeDescriptor(
        scope: LiveChannelScope,
        sort: ContentSortOption,
        playlistPrefix prefix: String,
        restriction: ContentRestriction,
        admittingHidden admitted: String?
    ) -> FetchDescriptor<LiveStream> {
        // Optionals so the predicate can test the optional `categoryId` against
        // them directly: neither `?? ""` nor a nil-check plus force-unwrap
        // survives SwiftData's SQL generation. Same shape as
        // `LiveChannelQuery.favoritesProbe`.
        let excluded = Set(restriction.excludedCategoryIDs.map(String?.some))
        let filters = !excluded.isEmpty
        let sortBy = LiveChannelQuery.sortDescriptors(for: scope, sort: sort)
        let predicate: Predicate<LiveStream>

        switch scope {
        case let .category(categoryId):
            if let admitted {
                predicate = #Predicate { stream in
                    stream.categoryId == categoryId
                        && stream.id.starts(with: prefix)
                        && (stream.isHidden == false || stream.id == admitted)
                        && (!filters || !excluded.contains(stream.categoryId))
                }
            } else {
                predicate = #Predicate { stream in
                    stream.categoryId == categoryId
                        && stream.id.starts(with: prefix)
                        && stream.isHidden == false
                        && (!filters || !excluded.contains(stream.categoryId))
                }
            }
        case .favorites:
            predicate = #Predicate { stream in
                stream.isFavorite
                    && stream.isHidden == false
                    && stream.id.starts(with: prefix)
                    && (!filters || !excluded.contains(stream.categoryId))
            }
        case .recentlyWatched:
            // Kept for exhaustiveness and for callers that want the scope as a
            // predicate: rings no longer walk it. Recently Watched is capped at
            // `recentLimit` *before* the browse list filters by playlist and
            // restriction, so a ring that filters first walks a different set of
            // channels — see `recentsRing(…)`.
            predicate = #Predicate { stream in
                stream.lastWatchedDate != nil
                    && stream.isHidden == false
                    && stream.id.starts(with: prefix)
                    && (!filters || !excluded.contains(stream.categoryId))
            }
        }
        return FetchDescriptor<LiveStream>(predicate: predicate, sortBy: sortBy)
    }

    /// A channel list a position can be read out of.
    private enum Ring {
        /// Addressed by position: how many channels it holds, and how to read any
        /// one of them without reading the rest.
        case positions(scope: FetchDescriptor<LiveStream>, count: Int)
        /// Already in memory. Recently Watched is the one list that arrives this
        /// way — see `recentsRing(…)`.
        case page([LiveStream])

        var count: Int {
            switch self {
            case let .positions(_, count): count
            case let .page(rows): rows.count
            }
        }

        func row(at index: Int, in context: ModelContext) -> LiveStream? {
            switch self {
            case let .positions(scope, _):
                try? context.fetch(positionDescriptor(scope, at: index)).first
            case let .page(rows):
                rows.indices.contains(index) ? rows[index] : nil
            }
        }

        /// Where `stream` sits in the list, or `nil` when the list doesn't hold
        /// it — which is also how the callers below ask whether a launch scope
        /// still contains the playing channel.
        func index(of stream: LiveStream, in context: ModelContext) -> Int? {
            switch self {
            case let .positions(scope, count):
                bisect(for: stream, scope: scope, count: count, in: context)
            case let .page(rows):
                rows.firstIndex { $0.id == stream.id }
            }
        }
    }

    /// A binary search over the same ordering SQLite sorts by: ~13 one-row reads
    /// for a 5,000-channel category, against 5,000 faulted rows for the fetch
    /// this replaced.
    private static func bisect(
        for stream: LiveStream,
        scope: FetchDescriptor<LiveStream>,
        count: Int,
        in context: ModelContext
    ) -> Int? {
        func row(at index: Int) -> LiveStream? {
            try? context.fetch(positionDescriptor(scope, at: index)).first
        }
        var low = 0
        var high = count
        while low < high {
            let mid = low + (high - low) / 2
            guard let row = row(at: mid) else { return nil }
            if compare(row, stream, using: scope.sortBy) == .orderedAscending {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < count else { return nil }
        // `low` is the first row that doesn't sort before the playing channel —
        // its position only when nothing ties with it. Provider lineups repeat
        // names freely, so the tied run is walked for the actual row rather than
        // the first of its equals being assumed. The walk ends at the first row
        // that doesn't tie, so a list with no repeats reads one page and stops
        // at its first row.
        var start = low
        while start < count {
            let tied = (try? context.fetch(positionDescriptor(scope, at: start, count: tiePage))) ?? []
            if tied.isEmpty { return nil }
            for (step, row) in tied.enumerated() {
                if row.id == stream.id { return start + step }
                if compare(row, stream, using: scope.sortBy) != .orderedSame { return nil }
            }
            start += tied.count
        }
        return nil
    }

    /// The list `current` is surfed within, and where it sits in it: the scope
    /// playback started from, falling back to the channel's own category when
    /// there is none or the channel has since dropped out of it (un-favorited,
    /// cleared from Recently Watched).
    private static func ring(
        around current: LiveStream,
        media: PlayableMedia,
        sort: ContentSortOption,
        restriction: ContentRestriction,
        playlist: Playlist,
        in context: ModelContext
    ) -> (ring: Ring, index: Int)? {
        let prefix = "\(playlist.id.uuidString)-"
        let ownCategory = current.categoryId.map(LiveChannelScope.category)
        // A category launch scope *is* the channel's own category, and the branch
        // below resolves that list anyway — asking for it here first would walk
        // it twice to get the same answer.
        if let scope = media.channelScope, scope != ownCategory,
           let located = locate(
               current, scope: scope, sort: sort, prefix: prefix,
               restriction: restriction, admittingHidden: nil, in: context
           )
        {
            return located
        }
        guard let categoryId = current.categoryId else { return nil }
        // A category locked away from this viewer surfs nowhere at all — not the
        // browse list below, and not the hidden-channel fallback either: a channel
        // a child somehow landed on must not become a doorway into the rest of a
        // category a parent locked. One check up front rather than a per-row
        // filter on each query: every row either query can return carries this
        // same category id, so the answer is the same for all of them.
        guard !restriction.hides(categoryID: categoryId) else { return nil }
        if let located = locate(
            current, scope: .category(categoryId), sort: sort, prefix: prefix,
            restriction: restriction, admittingHidden: nil, in: context
        ) {
            return located
        }
        // A hidden channel is in no browse list but can still be playing (recall,
        // a deep link) — surf its category rather than dead-end, with the playing
        // channel itself added back so it has a position in the ring. The *other*
        // hidden channels stay out: hiding a channel takes it out of the rotation.
        return locate(
            current, scope: .category(categoryId), sort: sort, prefix: prefix,
            restriction: restriction, admittingHidden: current.id, in: context
        )
    }

    private static func locate(
        _ current: LiveStream,
        scope: LiveChannelScope,
        sort: ContentSortOption,
        prefix: String,
        restriction: ContentRestriction,
        admittingHidden admitted: String?,
        in context: ModelContext
    ) -> (ring: Ring, index: Int)? {
        let ring: Ring
        if scope == .recentlyWatched {
            guard let recents = recentsRing(
                sort: sort, prefix: prefix, restriction: restriction, in: context
            ) else { return nil }
            ring = recents
        } else {
            let descriptor = scopeDescriptor(
                scope: scope, sort: sort, playlistPrefix: prefix,
                restriction: restriction, admittingHidden: admitted
            )
            guard let total = try? context.fetchCount(descriptor), total > 0 else { return nil }
            ring = .positions(scope: descriptor, count: total)
        }
        guard let index = ring.index(of: current, in: context) else { return nil }
        return (ring, index)
    }

    /// Recently Watched composed the way the browse list composes it: SQLite caps
    /// the newest `LiveChannelQuery.recentLimit` rows across *every* playlist, and
    /// only afterwards does `LiveChannelQuery.scoped` drop the rows belonging to
    /// another playlist or to a category this viewer can't see. A ring whose
    /// predicate carries the prefix and the restriction caps after filtering
    /// instead, which is this playlist's newest 50 — a different set of channels
    /// from the rail it claims to walk whenever a second playlist is installed.
    ///
    /// So this list is materialized, which the `Ring`'s positional reads exist to
    /// avoid: that cost is a live category running to thousands of rows, and it
    /// cannot arise behind a 50-row cap.
    private static func recentsRing(
        sort: ContentSortOption,
        prefix: String,
        restriction: ContentRestriction,
        in context: ModelContext
    ) -> Ring? {
        let descriptor = LiveChannelQuery.descriptor(for: .recentlyWatched, sort: sort)
        guard let page = try? context.fetch(descriptor) else { return nil }
        let rows = LiveChannelQuery.scoped(
            page, scope: .recentlyWatched, playlistPrefix: prefix, restriction: restriction
        )
        return rows.isEmpty ? nil : .page(rows)
    }

    /// Lexicographic comparison under a list of sort descriptors — the Swift
    /// statement of the ordering SQLite applies, which is what lets a position
    /// be found by bisection instead of by reading the list.
    private static func compare(
        _ lhs: LiveStream, _ rhs: LiveStream, using descriptors: [SortDescriptor<LiveStream>]
    ) -> ComparisonResult {
        for descriptor in descriptors {
            let result = descriptor.compare(lhs, rhs)
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }
}

// swiftlint:enable function_parameter_count

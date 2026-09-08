import Foundation
import SwiftData

@Model
final class LiveStream {
    // Live TV's Favorites / Recently Watched rows and the iCloud reconciler
    // filter channels by these columns; index them so a foreground refresh
    // seeks instead of scanning every channel on the main thread.
    // Selecting a Live TV category filters on `categoryId` (the single most
    // common Live TV query). Index it — and pair it with `isHidden`, which the
    // category predicate also tests — so a tap seeks the category's channels
    // instead of scanning every channel in a large playlist.
    // The standalone `isHidden` index serves the reconciler's export fetch
    // (`isFavorite || isHidden`): SQLite's OR optimization needs each disjunct
    // independently indexed, and the composite above can't serve `isHidden`
    // without a `categoryId` prefix — without it every reconcile scans the
    // whole channel table.
    // Live TV's Favorites and Recently Watched rows each filter on a user-state
    // column *and* `isHidden`, and with only the single-column indexes above
    // SQLite kept picking the worst of them: "SEARCH ZLIVESTREAM USING INDEX
    // …isHidden (ZISHIDDEN=?)" matches every visible channel (~54,000 on the
    // measured playlist) and then tests the favorite / last-watched column row
    // by row. Pairing each with `isHidden` turns that into a seek onto the
    // handful of rows the row actually renders: 7.6 ms -> 0.6 ms for favorites,
    // 12.5 ms -> 0.02 ms for recents.
    // Column order is not cosmetic. The equality term leads and the range /
    // sort term follows, which is the only arrangement SQLite picks *without*
    // table statistics: with `[lastWatchedDate, isHidden]` — the intuitive
    // order, filter column first — the planner still chose the ~54,000-row
    // `isHidden` index, because with no `sqlite_stat1` it assumes an equality
    // constraint beats a range one. `[isHidden, lastWatchedDate]` seeks on the
    // equality *and* satisfies `ORDER BY lastWatchedDate` from the index, so it
    // needs no ANALYZE to be chosen. `[categoryId, isHidden]` above is the same
    // rule, both terms being equalities.
    #Index<LiveStream>(
        [\.isFavorite],
        [\.lastWatchedDate],
        [\.categoryId],
        [\.categoryId, \.isHidden],
        [\.isHidden],
        [\.isFavorite, \.isHidden],
        [\.isHidden, \.lastWatchedDate]
    )

    @Attribute(.unique) var id: String
    var streamId: Int
    var name: String
    var streamIcon: String?
    var epgChannelId: String?
    var added: String?
    var customSid: String?
    var tvArchive: Int
    var tvArchiveDuration: Int
    var isAdult: Int
    var num: Int

    var categoryId: String?

    /// Full playback URL for streams that come from an m3u playlist. When set,
    /// playback uses it verbatim instead of building an Xtream URL from
    /// credentials and `streamId` (which is a derived hash for m3u sources).
    var directURL: String?

    var isFavorite: Bool = false
    var lastWatchedDate: Date?
    /// Hidden channels are kept in the store but excluded from browsing. Toggled
    /// from Content Management.
    var isHidden: Bool = false
    /// A user-defined order set in Content Management. `nil` means "follow the
    /// provider order" (`num`); once reordered, every channel in the category
    /// gets a dense value so it survives re-syncs.
    var customOrder: Int?
    /// A user-defined order for the Favorites collection, independent of the
    /// per-category `customOrder`. `nil` means "follow the provider order"; once
    /// the favorites are reordered in Content Management, every favorite gets a
    /// dense value so the arrangement survives re-syncs. Kept separate from
    /// `customOrder` because a channel's place among its category's channels and
    /// its place in the Favorites list are independent.
    var favoriteOrder: Int?

    init(
        id: String,
        streamId: Int,
        name: String,
        streamIcon: String? = nil,
        epgChannelId: String? = nil,
        added: String? = nil,
        customSid: String? = nil,
        tvArchive: Int = 0,
        tvArchiveDuration: Int = 0,
        isAdult: Int = 0,
        num: Int = 0,
        categoryId: String? = nil
    ) {
        self.id = id
        self.streamId = streamId
        self.name = name
        self.streamIcon = streamIcon
        self.epgChannelId = epgChannelId
        self.added = added
        self.customSid = customSid
        self.tvArchive = tvArchive
        self.tvArchiveDuration = tvArchiveDuration
        self.isAdult = isAdult
        self.num = num
        self.categoryId = categoryId
    }
}

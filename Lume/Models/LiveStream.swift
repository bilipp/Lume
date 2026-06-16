import Foundation
import SwiftData

@Model
final class LiveStream {
    // Live TV's Favorites / Recently Watched rows and the iCloud reconciler
    // filter channels by these columns; index them so a foreground refresh
    // seeks instead of scanning every channel on the main thread.
    #Index<LiveStream>([\.isFavorite], [\.lastWatchedDate])

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

import Foundation
import SwiftData

@Model
final class LiveStream {
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

    var isFavorite: Bool = false
    var lastWatchedDate: Date?
    /// Hidden channels are kept in the store but excluded from browsing. Toggled
    /// from Content Management.
    var isHidden: Bool = false
    /// A user-defined order set in Content Management. `nil` means "follow the
    /// provider order" (`num`); once reordered, every channel in the category
    /// gets a dense value so it survives re-syncs.
    var customOrder: Int?

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

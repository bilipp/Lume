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

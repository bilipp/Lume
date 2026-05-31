import Foundation
import SwiftData

@Model
final class EPGListing {
    @Attribute(.unique) var id: String

    /// The XMLTV channel ID this listing belongs to.
    /// LiveStreams reference the same value via their `epgChannelId`.
    var channelId: String
    var title: String
    var listingDescription: String
    var start: Date
    var end: Date

    init(
        id: String,
        channelId: String,
        title: String,
        listingDescription: String,
        start: Date,
        end: Date
    ) {
        self.id = id
        self.channelId = channelId
        self.title = title
        self.listingDescription = listingDescription
        self.start = start
        self.end = end
    }
}

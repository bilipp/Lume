import Foundation
import SwiftData

@Model
final class EPGListing {
    // EPG is the largest, fastest-growing table for big playlists (a multi-week
    // XMLTV guide for thousands of channels runs to hundreds of thousands of
    // rows). Every now/next lookup and the guide window query filter by
    // `channelId` and the `start`/`end` time bounds, so index them — without
    // these, each channel card and guide open scans the whole guide table.
    #Index<EPGListing>(
        [\.channelId],
        [\.start],
        [\.end],
        [\.channelId, \.start]
    )

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

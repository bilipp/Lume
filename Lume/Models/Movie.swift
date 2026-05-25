import Foundation
import SwiftData

@Model
final class Movie {
    @Attribute(.unique) var id: String
    var streamId: Int
    var name: String
    var streamIcon: String?
    var rating: Double
    var rating5Based: Double
    var added: String?
    var containerExtension: String?
    var tmdb: String?
    var num: Int
    var isAdult: Int

    var director: String?
    var actors: String?
    var plot: String?
    var genre: String?
    var releaseDate: String?
    var durationSecs: Int?
    var youtubeTrailer: String?

    var categoryId: String?

    var isFavorite: Bool = false
    var watchProgress: Double = 0.0
    var isWatched: Bool = false

    var downloadStatusRaw: String?
    var localFileURL: String?
    var downloadedAt: Date?

    var lastWatchedDate: Date?
    var addedToWatchlistDate: Date?

    var traktId: String?
    var tmdbId: Int?

    init(
        id: String,
        streamId: Int,
        name: String,
        streamIcon: String? = nil,
        rating: Double = 0,
        rating5Based: Double = 0,
        added: String? = nil,
        containerExtension: String? = nil,
        tmdb: String? = nil,
        num: Int = 0,
        isAdult: Int = 0,
        categoryId: String? = nil
    ) {
        self.id = id
        self.streamId = streamId
        self.name = name
        self.streamIcon = streamIcon
        self.rating = rating
        self.rating5Based = rating5Based
        self.added = added
        self.containerExtension = containerExtension
        self.tmdb = tmdb
        self.num = num
        self.isAdult = isAdult
        self.categoryId = categoryId
    }
}

enum DownloadStatus: String, Codable {
    case pending
    case downloading
    case completed
    case failed
}

extension Movie {
    var downloadStatus: DownloadStatus? {
        get {
            guard let raw = downloadStatusRaw else { return nil }
            return DownloadStatus(rawValue: raw)
        }
        set { downloadStatusRaw = newValue?.rawValue }
    }
}

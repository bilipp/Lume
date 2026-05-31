import Foundation

// MARK: - Server & User Info

struct XtreamAuthResponse: Decodable {
    let userInfo: XtreamUserInfo
    let serverInfo: XtreamServerInfo

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }
}

struct XtreamUserInfo: Decodable {
    let username: String?
    let status: String?
    let expDate: String?
    let isTrial: String?
    let activeCons: String?
    let maxConnections: String?

    enum CodingKeys: String, CodingKey {
        case username, status
        case expDate = "exp_date"
        case isTrial = "is_trial"
        case activeCons = "active_cons"
        case maxConnections = "max_connections"
    }
}

struct XtreamServerInfo: Decodable {
    let url: String?
    let port: String?
    let httpsPort: String?
    let serverProtocol: String?
    let timezone: String?
    let timestampNow: Int?
    let timeNow: String?

    enum CodingKeys: String, CodingKey {
        case url, port, timezone
        case httpsPort = "https_port"
        case serverProtocol = "server_protocol"
        case timestampNow = "timestamp_now"
        case timeNow = "time_now"
    }
}

// MARK: - Categories

struct XtreamCategory: Decodable {
    let categoryId: String
    let categoryName: String
    let parentId: Int?

    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryName = "category_name"
        case parentId = "parent_id"
    }
}

// MARK: - Live Streams

struct XtreamLiveStream: Decodable {
    let num: Int?
    let name: String?
    let streamType: String?
    let streamId: Int?
    let streamIcon: String?
    let epgChannelId: String?
    let added: String?
    let isAdult: Int?
    let categoryId: String?
    let customSid: String?
    let tvArchive: Int?
    let tvArchiveDuration: Int?

    enum CodingKeys: String, CodingKey {
        case num, name
        case streamType = "stream_type"
        case streamId = "stream_id"
        case streamIcon = "stream_icon"
        case epgChannelId = "epg_channel_id"
        case added
        case isAdult = "is_adult"
        case categoryId = "category_id"
        case customSid = "custom_sid"
        case tvArchive = "tv_archive"
        case tvArchiveDuration = "tv_archive_duration"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        num = try? container.decodeIfPresent(Int.self, forKey: .num)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        streamType = try? container.decodeIfPresent(String.self, forKey: .streamType)
        streamId = try? container.decodeIfPresent(Int.self, forKey: .streamId)
        streamIcon = try? container.decodeIfPresent(String.self, forKey: .streamIcon)
        epgChannelId = try? container.decodeIfPresent(String.self, forKey: .epgChannelId)
        added = try? container.decodeIfPresent(String.self, forKey: .added)

        if let isAdultInt = try? container.decodeIfPresent(Int.self, forKey: .isAdult) {
            isAdult = isAdultInt
        } else if let isAdultString = try? container.decodeIfPresent(String.self, forKey: .isAdult) {
            isAdult = Int(isAdultString)
        } else {
            isAdult = 0
        }

        if let catIdStr = try? container.decodeIfPresent(String.self, forKey: .categoryId) {
            categoryId = catIdStr
        } else if let catIdInt = try? container.decodeIfPresent(Int.self, forKey: .categoryId) {
            categoryId = String(catIdInt)
        } else {
            categoryId = nil
        }

        customSid = try? container.decodeIfPresent(String.self, forKey: .customSid)

        if let tvArchInt = try? container.decodeIfPresent(Int.self, forKey: .tvArchive) {
            tvArchive = tvArchInt
        } else if let tvArchStr = try? container.decodeIfPresent(String.self, forKey: .tvArchive) {
            tvArchive = Int(tvArchStr)
        } else {
            tvArchive = 0
        }

        if let tvArchDurInt = try? container.decodeIfPresent(Int.self, forKey: .tvArchiveDuration) {
            tvArchiveDuration = tvArchDurInt
        } else if let tvArchDurStr = try? container.decodeIfPresent(String.self, forKey: .tvArchiveDuration) {
            tvArchiveDuration = Int(tvArchDurStr)
        } else {
            tvArchiveDuration = 0
        }
    }
}

// MARK: - VOD Streams

struct XtreamVODStream: Decodable {
    let num: Int?
    let name: String?
    let streamType: String?
    let streamId: Int?
    let streamIcon: String?
    let rating: Double?
    let rating5Based: Double?
    let added: String?
    let isAdult: Int?
    let categoryId: String?
    let containerExtension: String?
    let tmdb: String?

    enum CodingKeys: String, CodingKey {
        case num, name
        case streamType = "stream_type"
        case streamId = "stream_id"
        case streamIcon = "stream_icon"
        case rating
        case rating5Based = "rating_5based"
        case added
        case isAdult = "is_adult"
        case categoryId = "category_id"
        case containerExtension = "container_extension"
        case tmdb
        case tmdbId = "tmdb_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        num = try? container.decodeIfPresent(Int.self, forKey: .num)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        streamType = try? container.decodeIfPresent(String.self, forKey: .streamType)
        streamId = try? container.decodeIfPresent(Int.self, forKey: .streamId)
        streamIcon = try? container.decodeIfPresent(String.self, forKey: .streamIcon)
        rating = Self.decodeDouble(from: container, forKey: .rating) ?? 0
        rating5Based = Self.decodeDouble(from: container, forKey: .rating5Based) ?? 0
        added = try? container.decodeIfPresent(String.self, forKey: .added)
        isAdult = Self.decodeInt(from: container, forKey: .isAdult) ?? 0
        categoryId = Self.decodeCategoryID(from: container, forKey: .categoryId)
        containerExtension = try? container.decodeIfPresent(String.self, forKey: .containerExtension)
        tmdb = Self.decodeTMDB(from: container)
    }

    private static func decodeDouble(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        } else if let str = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(str)
        }
        return nil
    }

    private static func decodeInt(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        } else if let str = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(str)
        }
        return nil
    }

    private static func decodeCategoryID(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
        if let str = try? container.decodeIfPresent(String.self, forKey: key) {
            return str
        } else if let int = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(int)
        }
        return nil
    }

    private static func decodeTMDB(from container: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let str = try? container.decodeIfPresent(String.self, forKey: .tmdb) {
            return str
        } else if let int = try? container.decodeIfPresent(Int.self, forKey: .tmdb) {
            return String(int)
        } else if let str = try? container.decodeIfPresent(String.self, forKey: .tmdbId) {
            return str
        } else if let int = try? container.decodeIfPresent(Int.self, forKey: .tmdbId) {
            return String(int)
        }
        return nil
    }
}

// MARK: - VOD Info

struct XtreamVODInfo: Decodable {
    let info: XtreamVODMetadata?
    let movieData: XtreamVODStreamData?

    enum CodingKeys: String, CodingKey {
        case info
        case movieData = "movie_data"
    }
}

struct XtreamVODMetadata: Decodable {
    let tmdbId: String?
    let name: String?
    let movieImage: String?
    let releaseDate: String?
    let durationSecs: Int?
    let youtubeTrailer: String?
    let director: String?
    let actors: String?
    let description: String?
    let plot: String?
    let genre: String?

    enum CodingKeys: String, CodingKey {
        case tmdbId = "tmdb_id"
        case name
        case movieImage = "movie_image"
        case releaseDate = "releasedate"
        case durationSecs = "duration_secs"
        case youtubeTrailer = "youtube_trailer"
        case director, actors, description, plot, genre
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        movieImage = try? container.decodeIfPresent(String.self, forKey: .movieImage)
        releaseDate = try? container.decodeIfPresent(String.self, forKey: .releaseDate)
        youtubeTrailer = try? container.decodeIfPresent(String.self, forKey: .youtubeTrailer)
        director = try? container.decodeIfPresent(String.self, forKey: .director)
        actors = try? container.decodeIfPresent(String.self, forKey: .actors)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        plot = try? container.decodeIfPresent(String.self, forKey: .plot)
        genre = try? container.decodeIfPresent(String.self, forKey: .genre)

        if let tmdbStr = try? container.decodeIfPresent(String.self, forKey: .tmdbId) {
            tmdbId = tmdbStr
        } else if let tmdbInt = try? container.decodeIfPresent(Int.self, forKey: .tmdbId) {
            tmdbId = String(tmdbInt)
        } else {
            tmdbId = nil
        }

        if let durInt = try? container.decodeIfPresent(Int.self, forKey: .durationSecs) {
            durationSecs = durInt
        } else if let durStr = try? container.decodeIfPresent(String.self, forKey: .durationSecs) {
            durationSecs = Int(durStr)
        } else {
            durationSecs = nil
        }
    }
}

struct XtreamVODStreamData: Decodable {
    let streamId: Int?
    let containerExtension: String?

    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id"
        case containerExtension = "container_extension"
    }
}

// MARK: - Series

struct XtreamSeries: Decodable {
    let num: Int?
    let name: String?
    let seriesId: Int?
    let cover: String?
    let plot: String?
    let cast: String?
    let director: String?
    let genre: String?
    let releaseDate: String?
    let lastModified: String?
    let rating: String?
    let rating5Based: String?
    let categoryId: String?
    let tmdb: String?

    enum CodingKeys: String, CodingKey {
        case num, name
        case seriesId = "series_id"
        case cover, plot, cast, director, genre
        case releaseDate
        case lastModified = "last_modified"
        case rating
        case rating5Based = "rating_5based"
        case categoryId = "category_id"
        case tmdb
        case tmdbId = "tmdb_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        num = try? container.decodeIfPresent(Int.self, forKey: .num)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        seriesId = try? container.decodeIfPresent(Int.self, forKey: .seriesId)
        cover = try? container.decodeIfPresent(String.self, forKey: .cover)
        plot = try? container.decodeIfPresent(String.self, forKey: .plot)
        cast = try? container.decodeIfPresent(String.self, forKey: .cast)
        director = try? container.decodeIfPresent(String.self, forKey: .director)
        genre = try? container.decodeIfPresent(String.self, forKey: .genre)
        releaseDate = try? container.decodeIfPresent(String.self, forKey: .releaseDate)
        lastModified = try? container.decodeIfPresent(String.self, forKey: .lastModified)
        rating = try? container.decodeIfPresent(String.self, forKey: .rating)
        rating5Based = try? container.decodeIfPresent(String.self, forKey: .rating5Based)

        if let catIdStr = try? container.decodeIfPresent(String.self, forKey: .categoryId) {
            categoryId = catIdStr
        } else if let catIdInt = try? container.decodeIfPresent(Int.self, forKey: .categoryId) {
            categoryId = String(catIdInt)
        } else {
            categoryId = nil
        }

        // Some playlists use "tmdb", others "tmdb_id"; accept either as String or Int.
        if let tmdbStr = try? container.decodeIfPresent(String.self, forKey: .tmdb) {
            tmdb = tmdbStr
        } else if let tmdbInt = try? container.decodeIfPresent(Int.self, forKey: .tmdb) {
            tmdb = String(tmdbInt)
        } else if let tmdbStr = try? container.decodeIfPresent(String.self, forKey: .tmdbId) {
            tmdb = tmdbStr
        } else if let tmdbInt = try? container.decodeIfPresent(Int.self, forKey: .tmdbId) {
            tmdb = String(tmdbInt)
        } else {
            tmdb = nil
        }
    }
}

// MARK: - Series Info

struct XtreamSeriesInfoResponse: Decodable {
    let info: XtreamSeriesInfo?
    let episodes: [String: [XtreamEpisode]]?
}

struct XtreamSeriesInfo: Decodable {
    let name: String?
    let cover: String?
    let plot: String?
    let cast: String?
    let director: String?
    let genre: String?
    let releaseDate: String?
    let lastModified: String?
    let rating: String?
    let tmdb: String?

    enum CodingKeys: String, CodingKey {
        case name, cover, plot, cast, director, genre
        case releaseDate
        case lastModified = "last_modified"
        case rating, tmdb
    }
}

struct XtreamEpisode: Decodable {
    let id: String?
    let episodeNum: Int?
    let title: String?
    let containerExtension: String?
    let customSid: String?
    let added: String?
    let season: Int?
    let directSource: String?
    let info: XtreamEpisodeInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case episodeNum = "episode_num"
        case title
        case containerExtension = "container_extension"
        case customSid = "custom_sid"
        case added, season
        case directSource = "direct_source"
        case info
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        episodeNum = try? container.decodeIfPresent(Int.self, forKey: .episodeNum)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        containerExtension = try? container.decodeIfPresent(String.self, forKey: .containerExtension)
        customSid = try? container.decodeIfPresent(String.self, forKey: .customSid)
        added = try? container.decodeIfPresent(String.self, forKey: .added)

        if let sInt = try? container.decodeIfPresent(Int.self, forKey: .season) {
            season = sInt
        } else if let sStr = try? container.decodeIfPresent(String.self, forKey: .season) {
            season = Int(sStr)
        } else {
            season = nil
        }

        directSource = try? container.decodeIfPresent(String.self, forKey: .directSource)
        info = try? container.decodeIfPresent(XtreamEpisodeInfo.self, forKey: .info)

        if let idStr = try? container.decodeIfPresent(String.self, forKey: .id) {
            id = idStr
        } else if let idInt = try? container.decodeIfPresent(Int.self, forKey: .id) {
            id = String(idInt)
        } else {
            id = nil
        }
    }
}

struct XtreamEpisodeInfo: Decodable {
    let airDate: String?
    let movieImage: String?
    let durationSecs: Int?
    let rating: Double?

    enum CodingKeys: String, CodingKey {
        case airDate = "air_date"
        case movieImage = "movie_image"
        case durationSecs = "duration_secs"
        case rating
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        airDate = try? container.decodeIfPresent(String.self, forKey: .airDate)
        movieImage = try? container.decodeIfPresent(String.self, forKey: .movieImage)

        if let rDouble = try? container.decodeIfPresent(Double.self, forKey: .rating) {
            rating = rDouble
        } else if let rString = try? container.decodeIfPresent(String.self, forKey: .rating) {
            rating = Double(rString)
        } else {
            rating = nil
        }

        if let durInt = try? container.decodeIfPresent(Int.self, forKey: .durationSecs) {
            durationSecs = durInt
        } else if let durStr = try? container.decodeIfPresent(String.self, forKey: .durationSecs) {
            durationSecs = Int(durStr)
        } else {
            durationSecs = nil
        }
    }
}

// MARK: - EPG

struct XtreamShortEPG: Decodable {
    let start: String?
    let end: String?
    let title: String?
    let description: String?
}

// MARK: - Bulk EPG (get_simple_data_table)

struct XtreamDataTableEPG: Decodable {
    let epgId: String?
    let title: String?
    let description: String?
    let startTimestamp: String?
    let endTimestamp: String?
    let start: String?
    let end: String?
    let channelId: String?
    let streamId: String?
    let id: String?

    enum CodingKeys: String, CodingKey {
        case epgId = "epg_id"
        case title, description
        case startTimestamp = "start_timestamp"
        case endTimestamp = "end_timestamp"
        case start, end
        case channelId = "channel_id"
        case streamId = "stream_id"
        case id
    }
}

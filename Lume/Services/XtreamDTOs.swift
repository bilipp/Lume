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
        self.num = try? container.decodeIfPresent(Int.self, forKey: .num)
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.streamType = try? container.decodeIfPresent(String.self, forKey: .streamType)
        self.streamId = try? container.decodeIfPresent(Int.self, forKey: .streamId)
        self.streamIcon = try? container.decodeIfPresent(String.self, forKey: .streamIcon)
        self.epgChannelId = try? container.decodeIfPresent(String.self, forKey: .epgChannelId)
        self.added = try? container.decodeIfPresent(String.self, forKey: .added)
        
        if let isAdultInt = try? container.decodeIfPresent(Int.self, forKey: .isAdult) {
            self.isAdult = isAdultInt
        } else if let isAdultString = try? container.decodeIfPresent(String.self, forKey: .isAdult) {
            self.isAdult = Int(isAdultString)
        } else {
            self.isAdult = 0
        }
        
        if let catIdStr = try? container.decodeIfPresent(String.self, forKey: .categoryId) {
            self.categoryId = catIdStr
        } else if let catIdInt = try? container.decodeIfPresent(Int.self, forKey: .categoryId) {
            self.categoryId = String(catIdInt)
        } else {
            self.categoryId = nil
        }
        
        self.customSid = try? container.decodeIfPresent(String.self, forKey: .customSid)
        
        if let tvArchInt = try? container.decodeIfPresent(Int.self, forKey: .tvArchive) {
            self.tvArchive = tvArchInt
        } else if let tvArchStr = try? container.decodeIfPresent(String.self, forKey: .tvArchive) {
            self.tvArchive = Int(tvArchStr)
        } else {
            self.tvArchive = 0
        }
        
        if let tvArchDurInt = try? container.decodeIfPresent(Int.self, forKey: .tvArchiveDuration) {
            self.tvArchiveDuration = tvArchDurInt
        } else if let tvArchDurStr = try? container.decodeIfPresent(String.self, forKey: .tvArchiveDuration) {
            self.tvArchiveDuration = Int(tvArchDurStr)
        } else {
            self.tvArchiveDuration = 0
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
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.num = try? container.decodeIfPresent(Int.self, forKey: .num)
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.streamType = try? container.decodeIfPresent(String.self, forKey: .streamType)
        self.streamId = try? container.decodeIfPresent(Int.self, forKey: .streamId)
        self.streamIcon = try? container.decodeIfPresent(String.self, forKey: .streamIcon)
        
        if let rDouble = try? container.decodeIfPresent(Double.self, forKey: .rating) {
            self.rating = rDouble
        } else if let rString = try? container.decodeIfPresent(String.self, forKey: .rating) {
            self.rating = Double(rString)
        } else {
            self.rating = 0.0
        }
        
        if let rDouble = try? container.decodeIfPresent(Double.self, forKey: .rating5Based) {
            self.rating5Based = rDouble
        } else if let rString = try? container.decodeIfPresent(String.self, forKey: .rating5Based) {
            self.rating5Based = Double(rString)
        } else {
            self.rating5Based = 0.0
        }
        
        self.added = try? container.decodeIfPresent(String.self, forKey: .added)
        
        if let isAdultInt = try? container.decodeIfPresent(Int.self, forKey: .isAdult) {
            self.isAdult = isAdultInt
        } else if let isAdultString = try? container.decodeIfPresent(String.self, forKey: .isAdult) {
            self.isAdult = Int(isAdultString)
        } else {
            self.isAdult = 0
        }
        
        if let catIdStr = try? container.decodeIfPresent(String.self, forKey: .categoryId) {
            self.categoryId = catIdStr
        } else if let catIdInt = try? container.decodeIfPresent(Int.self, forKey: .categoryId) {
            self.categoryId = String(catIdInt)
        } else {
            self.categoryId = nil
        }
        
        self.containerExtension = try? container.decodeIfPresent(String.self, forKey: .containerExtension)
        
        if let tmdbStr = try? container.decodeIfPresent(String.self, forKey: .tmdb) {
            self.tmdb = tmdbStr
        } else if let tmdbInt = try? container.decodeIfPresent(Int.self, forKey: .tmdb) {
            self.tmdb = String(tmdbInt)
        } else {
            self.tmdb = nil
        }
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
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.movieImage = try? container.decodeIfPresent(String.self, forKey: .movieImage)
        self.releaseDate = try? container.decodeIfPresent(String.self, forKey: .releaseDate)
        self.youtubeTrailer = try? container.decodeIfPresent(String.self, forKey: .youtubeTrailer)
        self.director = try? container.decodeIfPresent(String.self, forKey: .director)
        self.actors = try? container.decodeIfPresent(String.self, forKey: .actors)
        self.description = try? container.decodeIfPresent(String.self, forKey: .description)
        self.plot = try? container.decodeIfPresent(String.self, forKey: .plot)
        self.genre = try? container.decodeIfPresent(String.self, forKey: .genre)
        
        if let tmdbStr = try? container.decodeIfPresent(String.self, forKey: .tmdbId) {
            self.tmdbId = tmdbStr
        } else if let tmdbInt = try? container.decodeIfPresent(Int.self, forKey: .tmdbId) {
            self.tmdbId = String(tmdbInt)
        } else {
            self.tmdbId = nil
        }
        
        if let durInt = try? container.decodeIfPresent(Int.self, forKey: .durationSecs) {
            self.durationSecs = durInt
        } else if let durStr = try? container.decodeIfPresent(String.self, forKey: .durationSecs) {
            self.durationSecs = Int(durStr)
        } else {
            self.durationSecs = nil
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
        case releaseDate = "releaseDate"
        case lastModified = "last_modified"
        case rating
        case rating5Based = "rating_5based"
        case categoryId = "category_id"
        case tmdb
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.num = try? container.decodeIfPresent(Int.self, forKey: .num)
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.seriesId = try? container.decodeIfPresent(Int.self, forKey: .seriesId)
        self.cover = try? container.decodeIfPresent(String.self, forKey: .cover)
        self.plot = try? container.decodeIfPresent(String.self, forKey: .plot)
        self.cast = try? container.decodeIfPresent(String.self, forKey: .cast)
        self.director = try? container.decodeIfPresent(String.self, forKey: .director)
        self.genre = try? container.decodeIfPresent(String.self, forKey: .genre)
        self.releaseDate = try? container.decodeIfPresent(String.self, forKey: .releaseDate)
        self.lastModified = try? container.decodeIfPresent(String.self, forKey: .lastModified)
        self.rating = try? container.decodeIfPresent(String.self, forKey: .rating)
        self.rating5Based = try? container.decodeIfPresent(String.self, forKey: .rating5Based)
        
        if let catIdStr = try? container.decodeIfPresent(String.self, forKey: .categoryId) {
            self.categoryId = catIdStr
        } else if let catIdInt = try? container.decodeIfPresent(Int.self, forKey: .categoryId) {
            self.categoryId = String(catIdInt)
        } else {
            self.categoryId = nil
        }
        
        if let tmdbStr = try? container.decodeIfPresent(String.self, forKey: .tmdb) {
            self.tmdb = tmdbStr
        } else if let tmdbInt = try? container.decodeIfPresent(Int.self, forKey: .tmdb) {
            self.tmdb = String(tmdbInt)
        } else {
            self.tmdb = nil
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
        case releaseDate = "releaseDate"
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
        self.episodeNum = try? container.decodeIfPresent(Int.self, forKey: .episodeNum)
        self.title = try? container.decodeIfPresent(String.self, forKey: .title)
        self.containerExtension = try? container.decodeIfPresent(String.self, forKey: .containerExtension)
        self.customSid = try? container.decodeIfPresent(String.self, forKey: .customSid)
        self.added = try? container.decodeIfPresent(String.self, forKey: .added)
        
        if let sInt = try? container.decodeIfPresent(Int.self, forKey: .season) {
            self.season = sInt
        } else if let sStr = try? container.decodeIfPresent(String.self, forKey: .season) {
            self.season = Int(sStr)
        } else {
            self.season = nil
        }
        
        self.directSource = try? container.decodeIfPresent(String.self, forKey: .directSource)
        self.info = try? container.decodeIfPresent(XtreamEpisodeInfo.self, forKey: .info)
        
        if let idStr = try? container.decodeIfPresent(String.self, forKey: .id) {
            self.id = idStr
        } else if let idInt = try? container.decodeIfPresent(Int.self, forKey: .id) {
            self.id = String(idInt)
        } else {
            self.id = nil
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
        self.airDate = try? container.decodeIfPresent(String.self, forKey: .airDate)
        self.movieImage = try? container.decodeIfPresent(String.self, forKey: .movieImage)
        
        if let rDouble = try? container.decodeIfPresent(Double.self, forKey: .rating) {
            self.rating = rDouble
        } else if let rString = try? container.decodeIfPresent(String.self, forKey: .rating) {
            self.rating = Double(rString)
        } else {
            self.rating = nil
        }
        
        if let durInt = try? container.decodeIfPresent(Int.self, forKey: .durationSecs) {
            self.durationSecs = durInt
        } else if let durStr = try? container.decodeIfPresent(String.self, forKey: .durationSecs) {
            self.durationSecs = Int(durStr)
        } else {
            self.durationSecs = nil
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

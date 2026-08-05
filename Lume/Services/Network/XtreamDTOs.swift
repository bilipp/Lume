import Foundation

// MARK: - Lenient field decoding

/// Xtream panel forks disagree on JSON types field by field — the same key can
/// arrive as a string on one provider and a number on the next. These helpers
/// accept either representation (and swallow null / absent keys) so a single
/// odd field can't fail a whole response.
extension KeyedDecodingContainer {
    func lenientString(forKey key: Key) -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) { return string }
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return String(int) }
        if let double = try? decodeIfPresent(Double.self, forKey: key) { return String(double) }
        return nil
    }

    func lenientInt(forKey key: Key) -> Int? {
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return int }
        if let string = try? decodeIfPresent(String.self, forKey: key) { return Int(string) }
        if let double = try? decodeIfPresent(Double.self, forKey: key) { return Int(double) }
        return nil
    }

    func lenientDouble(forKey key: Key) -> Double? {
        if let double = try? decodeIfPresent(Double.self, forKey: key) { return double }
        if let string = try? decodeIfPresent(String.self, forKey: key) { return Double(string) }
        return nil
    }
}

// MARK: - Lenient list decoding

/// A list endpoint payload. Panels return either a JSON array or — on some
/// forks — an object keyed by index ("0", "1", …); an individual element that
/// still fails to decode is dropped rather than failing the whole request.
///
/// If the payload has entries but *none* decodes (e.g. an HTML block page that
/// happens to be JSON, or an `{"error": …}` body), the first element error is
/// rethrown: reporting garbage as "zero items" would let the sync prune the
/// entire catalog.
struct XtreamList<Element: Decodable>: Decodable {
    let items: [Element]

    /// Decoded in place of an element that failed, purely to advance the
    /// unkeyed container past the bad value.
    private struct SkippedValue: Decodable {
        init(from _: Decoder) throws {}
    }

    private struct IndexKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = Int(stringValue)
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            var result: [Element] = []
            var firstError: Error?
            while !unkeyed.isAtEnd {
                do {
                    try result.append(unkeyed.decode(Element.self))
                } catch {
                    firstError = firstError ?? error
                    if (try? unkeyed.decode(SkippedValue.self)) == nil {
                        break // cannot advance past the bad value — bail rather than spin
                    }
                }
            }
            if result.isEmpty, let firstError { throw firstError }
            items = result
            return
        }

        let keyed = try decoder.container(keyedBy: IndexKey.self)
        let sortedKeys = keyed.allKeys.sorted {
            ($0.intValue ?? .max, $0.stringValue) < ($1.intValue ?? .max, $1.stringValue)
        }
        var result: [Element] = []
        var firstError: Error?
        for key in sortedKeys {
            do {
                try result.append(keyed.decode(Element.self, forKey: key))
            } catch {
                firstError = firstError ?? error
            }
        }
        if result.isEmpty, let firstError { throw firstError }
        items = result
    }
}

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = container.lenientString(forKey: .username)
        status = container.lenientString(forKey: .status)
        expDate = container.lenientString(forKey: .expDate)
        isTrial = container.lenientString(forKey: .isTrial)
        activeCons = container.lenientString(forKey: .activeCons)
        maxConnections = container.lenientString(forKey: .maxConnections)
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.lenientString(forKey: .url)
        port = container.lenientString(forKey: .port)
        httpsPort = container.lenientString(forKey: .httpsPort)
        serverProtocol = container.lenientString(forKey: .serverProtocol)
        timezone = container.lenientString(forKey: .timezone)
        timestampNow = container.lenientInt(forKey: .timestampNow)
        timeNow = container.lenientString(forKey: .timeNow)
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A category is unusable without an id (sync keys on it) — throwing
        // here drops just this entry when decoded through `XtreamList`.
        guard let id = container.lenientString(forKey: .categoryId) else {
            throw DecodingError.keyNotFound(
                CodingKeys.categoryId,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "category_id missing or not a string/number"
                )
            )
        }
        categoryId = id
        categoryName = container.lenientString(forKey: .categoryName) ?? ""
        parentId = container.lenientInt(forKey: .parentId)
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
        num = container.lenientInt(forKey: .num)
        name = container.lenientString(forKey: .name)
        streamType = container.lenientString(forKey: .streamType)
        streamId = container.lenientInt(forKey: .streamId)
        streamIcon = container.lenientString(forKey: .streamIcon)
        epgChannelId = container.lenientString(forKey: .epgChannelId)
        added = container.lenientString(forKey: .added)
        isAdult = container.lenientInt(forKey: .isAdult) ?? 0
        categoryId = container.lenientString(forKey: .categoryId)
        customSid = container.lenientString(forKey: .customSid)
        tvArchive = container.lenientInt(forKey: .tvArchive) ?? 0
        tvArchiveDuration = container.lenientInt(forKey: .tvArchiveDuration) ?? 0
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
        num = container.lenientInt(forKey: .num)
        name = container.lenientString(forKey: .name)
        streamType = container.lenientString(forKey: .streamType)
        streamId = container.lenientInt(forKey: .streamId)
        streamIcon = container.lenientString(forKey: .streamIcon)
        rating = container.lenientDouble(forKey: .rating) ?? 0
        rating5Based = container.lenientDouble(forKey: .rating5Based) ?? 0
        added = container.lenientString(forKey: .added)
        isAdult = container.lenientInt(forKey: .isAdult) ?? 0
        categoryId = container.lenientString(forKey: .categoryId)
        containerExtension = container.lenientString(forKey: .containerExtension)
        // Some playlists use "tmdb", others "tmdb_id".
        tmdb = container.lenientString(forKey: .tmdb) ?? container.lenientString(forKey: .tmdbId)
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Panels emit an empty array instead of an object when a section has
        // no data — tolerate any malformed section rather than fail the call.
        info = try? container.decodeIfPresent(XtreamVODMetadata.self, forKey: .info)
        movieData = try? container.decodeIfPresent(XtreamVODStreamData.self, forKey: .movieData)
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
        tmdbId = container.lenientString(forKey: .tmdbId)
        name = container.lenientString(forKey: .name)
        movieImage = container.lenientString(forKey: .movieImage)
        releaseDate = container.lenientString(forKey: .releaseDate)
        durationSecs = container.lenientInt(forKey: .durationSecs)
        youtubeTrailer = container.lenientString(forKey: .youtubeTrailer)
        director = container.lenientString(forKey: .director)
        actors = container.lenientString(forKey: .actors)
        description = container.lenientString(forKey: .description)
        plot = container.lenientString(forKey: .plot)
        genre = container.lenientString(forKey: .genre)
    }
}

struct XtreamVODStreamData: Decodable {
    let streamId: Int?
    let containerExtension: String?

    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id"
        case containerExtension = "container_extension"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamId = container.lenientInt(forKey: .streamId)
        containerExtension = container.lenientString(forKey: .containerExtension)
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
        num = container.lenientInt(forKey: .num)
        name = container.lenientString(forKey: .name)
        seriesId = container.lenientInt(forKey: .seriesId)
        cover = container.lenientString(forKey: .cover)
        plot = container.lenientString(forKey: .plot)
        cast = container.lenientString(forKey: .cast)
        director = container.lenientString(forKey: .director)
        genre = container.lenientString(forKey: .genre)
        releaseDate = container.lenientString(forKey: .releaseDate)
        lastModified = container.lenientString(forKey: .lastModified)
        rating = container.lenientString(forKey: .rating)
        rating5Based = container.lenientString(forKey: .rating5Based)
        categoryId = container.lenientString(forKey: .categoryId)
        // Some playlists use "tmdb", others "tmdb_id".
        tmdb = container.lenientString(forKey: .tmdb) ?? container.lenientString(forKey: .tmdbId)
    }
}

// MARK: - Series Info

struct XtreamSeriesInfoResponse: Decodable {
    let info: XtreamSeriesInfo?
    let episodes: [String: [XtreamEpisode]]?

    enum CodingKeys: String, CodingKey {
        case info, episodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        info = try? container.decodeIfPresent(XtreamSeriesInfo.self, forKey: .info)

        // Canonically an object keyed by season number, but panels also send a
        // flat episode array or an array of per-season arrays.
        if let dict = try? container.decodeIfPresent([String: XtreamList<XtreamEpisode>].self, forKey: .episodes) {
            episodes = dict.mapValues(\.items)
        } else if let flat = try? container.decodeIfPresent(XtreamList<XtreamEpisode>.self, forKey: .episodes) {
            episodes = Dictionary(grouping: flat.items) { String($0.season ?? 1) }
        } else if let seasons = try? container.decodeIfPresent([XtreamList<XtreamEpisode>].self, forKey: .episodes) {
            var grouped: [String: [XtreamEpisode]] = [:]
            for (index, season) in seasons.enumerated() where !season.items.isEmpty {
                let seasonNum = season.items.first?.season ?? index + 1
                grouped[String(seasonNum), default: []] += season.items
            }
            episodes = grouped.isEmpty ? nil : grouped
        } else {
            episodes = nil
        }
    }
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(forKey: .name)
        cover = container.lenientString(forKey: .cover)
        plot = container.lenientString(forKey: .plot)
        cast = container.lenientString(forKey: .cast)
        director = container.lenientString(forKey: .director)
        genre = container.lenientString(forKey: .genre)
        releaseDate = container.lenientString(forKey: .releaseDate)
        lastModified = container.lenientString(forKey: .lastModified)
        rating = container.lenientString(forKey: .rating)
        tmdb = container.lenientString(forKey: .tmdb)
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
        id = container.lenientString(forKey: .id)
        episodeNum = container.lenientInt(forKey: .episodeNum)
        title = container.lenientString(forKey: .title)
        containerExtension = container.lenientString(forKey: .containerExtension)
        customSid = container.lenientString(forKey: .customSid)
        added = container.lenientString(forKey: .added)
        season = container.lenientInt(forKey: .season)
        directSource = container.lenientString(forKey: .directSource)
        info = try? container.decodeIfPresent(XtreamEpisodeInfo.self, forKey: .info)
    }
}

struct XtreamEpisodeInfo: Decodable {
    let airDate: String?
    let movieImage: String?
    let durationSecs: Int?
    let rating: Double?
    let plot: String?

    enum CodingKeys: String, CodingKey {
        case airDate = "air_date"
        case releaseDate
        case movieImage = "movie_image"
        case durationSecs = "duration_secs"
        case rating
        case plot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        airDate = container.lenientString(forKey: .airDate) ?? container.lenientString(forKey: .releaseDate)
        movieImage = container.lenientString(forKey: .movieImage)
        durationSecs = container.lenientInt(forKey: .durationSecs)
        rating = container.lenientDouble(forKey: .rating)
        plot = container.lenientString(forKey: .plot)
    }
}

// MARK: - EPG

struct XtreamShortEPG: Decodable {
    let start: String?
    let end: String?
    let title: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case start, end, title, description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = container.lenientString(forKey: .start)
        end = container.lenientString(forKey: .end)
        title = container.lenientString(forKey: .title)
        description = container.lenientString(forKey: .description)
    }
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

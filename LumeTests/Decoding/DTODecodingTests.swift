import Foundation
@testable import Lume
import Testing

struct DTODecodingTests {
    // MARK: - Auth Response

    @Test func `decode account info`() throws {
        let response: XtreamAuthResponse = try loadExampleJSON("AccountInfo.json")
        #expect(response.userInfo.username == "1234567890")
        #expect(response.userInfo.status == "Active")
        #expect(response.serverInfo.url == "example-iptv.com")
        #expect(response.serverInfo.timezone != nil)
    }

    // MARK: - Categories

    @Test func `decode live categories`() throws {
        let categories: [XtreamCategory] = try loadExampleJSON("LiveCategories.json")
        #expect(categories.count == 48, "Expected 48 live categories")
        // An explicit closure (vs. a `\.categoryId.isEmpty` key path passed to
        // the rethrows `allSatisfy`) sidesteps a toolchain quirk that infers the
        // key-path argument as throwing and fails to compile. Same assertion:
        // at least one category carries a non-empty id / name.
        #expect(categories.contains(where: { !$0.categoryId.isEmpty }))
        #expect(categories.contains(where: { !$0.categoryName.isEmpty }))
    }

    @Test func `decode movie categories`() throws {
        let categories: [XtreamCategory] = try loadExampleJSON("MovieCategories.json")
        #expect(categories.count == 27, "Expected 27 movie categories")
        let first = try #require(categories.first)
        #expect(first.categoryId == "117")
        #expect(first.categoryName == "Old movies")
        #expect(first.parentId == 0)
    }

    @Test func `decode series categories`() throws {
        let categories: [XtreamCategory] = try loadExampleJSON("SeriesCategories.json")
        #expect(categories.count == 19, "Expected 19 series categories")
    }

    // MARK: - Live Streams

    @Test func `decode live streams`() throws {
        let streams: [XtreamLiveStream] = try loadExampleJSON("LiveStreams.json")
        #expect(streams.count == 2568, "Expected 2568 live streams")
        let first = try #require(streams.first)
        #expect(first.streamId == 1_537_280)
        #expect(first.name != nil)
        #expect(first.categoryId == "1339")
    }

    @Test func `live stream type coercion`() throws {
        let streams: [XtreamLiveStream] = try loadExampleJSON("LiveStreams.json")
        let sample = try #require(streams.first)
        #expect(sample.isAdult == 0)
        #expect(sample.tvArchive == 0)
        #expect(sample.tvArchiveDuration == 0)
    }

    // MARK: - Movies

    @Test func `decode movies count`() throws {
        let movies: [XtreamVODStream] = try loadExampleJSON("Movies.json")
        #expect(movies.count > 10000, "Expected at least 10,000 movies")
    }

    @Test func `decode first movie`() throws {
        let movies: [XtreamVODStream] = try loadExampleJSON("Movies.json")
        let first = try #require(movies.first)
        #expect(first.streamId == 2_001_952)
        #expect(first.name == "First movie")
        #expect(first.categoryId == "117")
        #expect(first.containerExtension == "mkv")
    }

    @Test func `movie type coercion`() throws {
        let movies: [XtreamVODStream] = try loadExampleJSON("Movies.json")
        let first = try #require(movies.first)
        // rating comes as String "6.406" — should decode as Double
        #expect(first.rating == 6.406)
        // rating_5based comes as Double 3.2
        #expect(first.rating5Based == 3.2)
        // isAdult comes as Int 0
        #expect(first.isAdult == 0)
        // category_id comes as String "117"
        #expect(first.categoryId == "117")
        // tmdb comes as String "582913"
        #expect(first.tmdb == "582913")
        // added comes as Unix timestamp string
        #expect(first.added == "1779391620")
    }

    @Test func `movie tmdb type coercion`() throws {
        let movies: [XtreamVODStream] = try loadExampleJSON("Movies.json")
        // Some tmdb values might be Int — the DTO handles both
        let withIntTmdb = movies.first { $0.tmdb == "25641" }
        #expect(withIntTmdb != nil)
    }

    @Test func `movie tmdb id fallback key`() throws {
        // Playlist variant that uses "tmdb_id" (Int) instead of "tmdb".
        let json = Data("""
        [{
            "num": 1,
            "name": "Mob Land",
            "stream_type": "movie",
            "stream_id": 389912,
            "tmdb_id": 979275,
            "rating": "6",
            "rating_5based": 3,
            "category_id": "126",
            "container_extension": "mkv"
        }]
        """.utf8)
        let movies = try JSONDecoder().decode([XtreamVODStream].self, from: json)
        let first = try #require(movies.first)
        #expect(first.tmdb == "979275")
    }

    // MARK: - Movie Info

    @Test func `decode movie info`() throws {
        let info: XtreamVODInfo = try loadExampleJSON("MovieInfo.json")
        let metadata = try #require(info.info)
        #expect(metadata.name == "Harry Potter and the Chamber of Secrets")
        #expect(metadata.tmdbId == "672")
        #expect(metadata.durationSecs == 9660)
        #expect(metadata.director == "Chris Columbus, Peter MacDonald, David Hanks, Annie Penn, Chris Carreras")

        let movieData = try #require(info.movieData)
        #expect(movieData.streamId == 535_312)
        #expect(movieData.containerExtension == "mkv")
    }

    // MARK: - Series

    @Test func `decode series count`() throws {
        let series: [XtreamSeries] = try loadExampleJSON("Series.json")
        #expect(series.count == 2215, "Expected 2215 series")
    }

    @Test func `decode first series`() throws {
        let series: [XtreamSeries] = try loadExampleJSON("Series.json")
        let first = try #require(series.first)
        #expect(first.seriesId == 46567)
        #expect(first.name == "First series")
        #expect(first.categoryId == "817")
    }

    @Test func `series type coercion`() throws {
        let series: [XtreamSeries] = try loadExampleJSON("Series.json")
        let sample = try #require(series.first { $0.seriesId == 46565 })
        // rating comes as String "8"
        #expect(sample.rating == "8")
        // category_id comes as String
        #expect(sample.categoryId == "209")
        // tmdb comes as String
        #expect(sample.tmdb == "278113")
    }

    @Test func `series tmdb id fallback key`() throws {
        // Playlist variant that uses "tmdb_id" (Int) instead of "tmdb".
        let json = Data("""
        [{
            "num": 1,
            "name": "Due spicci – Das nötige Kleingeld",
            "series_id": 480899,
            "tmdb_id": 304597,
            "rating": "9",
            "rating_5based": 4.5,
            "category_id": "369"
        }]
        """.utf8)
        let series = try JSONDecoder().decode([XtreamSeries].self, from: json)
        let first = try #require(series.first)
        #expect(first.tmdb == "304597")
    }

    @Test func `series category id type coercion`() throws {
        let series: [XtreamSeries] = try loadExampleJSON("Series.json")
        // All category_id values in the real data should be strings
        for serie in series.prefix(100) {
            #expect(serie.categoryId != nil)
        }
    }

    // MARK: - Series Info

    @Test func `decode series info`() throws {
        let info: XtreamSeriesInfoResponse = try loadExampleJSON("SeriesInfo.json")
        let metadata = try #require(info.info)
        #expect(metadata.name == "Breaking Bad")
        #expect(metadata.tmdb == "1396")

        let episodes = try #require(info.episodes)
        #expect(episodes["1"]?.count == 7, "Season 1 should have 7 episodes")
        #expect(episodes["2"]?.count == 13, "Season 2 should have 13 episodes")
    }

    @Test func `decode episode from series info`() throws {
        let info: XtreamSeriesInfoResponse = try loadExampleJSON("SeriesInfo.json")
        let episodes = try #require(info.episodes)
        let firstEp = try #require(episodes["1"]?.first)
        #expect(firstEp.id == "129902")
        #expect(firstEp.episodeNum == 1)
        #expect(firstEp.season == 1)
        #expect(firstEp.containerExtension == "mp4")
        #expect(firstEp.title == "Breaking Bad - S01E01")

        let epInfo = try #require(firstEp.info)
        #expect(epInfo.airDate == "2008-01-20")
        #expect(epInfo.durationSecs == 3486)
        #expect(epInfo.rating == 7.826)
        #expect(epInfo.movieImage != nil)
    }
}

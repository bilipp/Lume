import Foundation
@testable import Lume
import Testing

struct DTODecodingEdgeCaseTests {
    // MARK: - XtreamEpisode ID/Season coercion

    @Test func `episode decodes string ID`() throws {
        let json = Data("""
        {"id": "129902", "episode_num": 1, "season": 1}
        """.utf8)
        let episode = try JSONDecoder().decode(XtreamEpisode.self, from: json)
        #expect(episode.id == "129902")
        #expect(episode.season == 1)
    }

    @Test func `episode decodes int ID`() throws {
        let json = Data("""
        {"id": 12345, "episode_num": 2, "season": "2"}
        """.utf8)
        let episode = try JSONDecoder().decode(XtreamEpisode.self, from: json)
        #expect(episode.id == "12345")
        #expect(episode.season == 2)
    }

    @Test func `episode missing ID`() throws {
        let json = Data("""
        {"episode_num": 1}
        """.utf8)
        let episode = try JSONDecoder().decode(XtreamEpisode.self, from: json)
        #expect(episode.id == nil)
    }

    @Test func `episode decodes with info`() throws {
        let json = Data("""
        {
            "id": "1",
            "episode_num": 1,
            "title": "Pilot",
            "container_extension": "mp4",
            "info": {
                "air_date": "2024-01-15",
                "movie_image": "http://example.com/ep.jpg",
                "duration_secs": "3600",
                "rating": "7.5"
            }
        }
        """.utf8)
        let episode = try JSONDecoder().decode(XtreamEpisode.self, from: json)
        #expect(episode.id == "1")
        #expect(episode.title == "Pilot")
        #expect(episode.containerExtension == "mp4")

        let info = try #require(episode.info)
        #expect(info.airDate == "2024-01-15")
        #expect(info.movieImage == "http://example.com/ep.jpg")
        #expect(info.durationSecs == 3600)
        #expect(info.rating == 7.5)
    }

    @Test func `episode info rating as string`() throws {
        let json = Data("""
        {
            "id": "1",
            "episode_num": 1,
            "info": {"rating": "8.2"}
        }
        """.utf8)
        let episode = try JSONDecoder().decode(XtreamEpisode.self, from: json)
        #expect(episode.info?.rating == 8.2)
    }

    @Test func `episode info duration as string`() throws {
        let json = Data("""
        {
            "id": "1",
            "episode_num": 1,
            "info": {"duration_secs": "1800"}
        }
        """.utf8)
        let episode = try JSONDecoder().decode(XtreamEpisode.self, from: json)
        #expect(episode.info?.durationSecs == 1800)
    }

    @Test func `episode info missing fields`() throws {
        let json = Data("""
        {"id": "1", "episode_num": 1, "info": {}}
        """.utf8)
        let episode = try JSONDecoder().decode(XtreamEpisode.self, from: json)
        #expect(episode.info?.airDate == nil)
        #expect(episode.info?.durationSecs == nil)
        #expect(episode.info?.rating == nil)
    }

    // MARK: - XtreamShortEPG

    @Test func `short EPG decodes`() throws {
        let json = Data("""
        {"start": "1700000000", "end": "1700003600", "title": "News", "description": "News program"}
        """.utf8)
        let epg = try JSONDecoder().decode(XtreamShortEPG.self, from: json)
        #expect(epg.title == "News")
        #expect(epg.description == "News program")
        #expect(epg.start == "1700000000")
        #expect(epg.end == "1700003600")
    }

    @Test func `short EPG with nil fields`() throws {
        let json = Data("""
        {"start": null, "end": null, "title": null, "description": null}
        """.utf8)
        let epg = try JSONDecoder().decode(XtreamShortEPG.self, from: json)
        #expect(epg.title == nil)
        #expect(epg.description == nil)
    }

    // MARK: - XtreamLiveStream coercion variants

    @Test func `live stream category ID as int`() throws {
        let json = Data("""
        {"stream_id": 1, "category_id": 42}
        """.utf8)
        let stream = try JSONDecoder().decode(XtreamLiveStream.self, from: json)
        #expect(stream.categoryId == "42")
    }

    @Test func `live stream category ID as string`() throws {
        let json = Data("""
        {"stream_id": 1, "category_id": "42"}
        """.utf8)
        let stream = try JSONDecoder().decode(XtreamLiveStream.self, from: json)
        #expect(stream.categoryId == "42")
    }

    @Test func `live stream is adult coercion`() throws {
        let json = Data("""
        {"stream_id": 1, "is_adult": "1"}
        """.utf8)
        let stream = try JSONDecoder().decode(XtreamLiveStream.self, from: json)
        #expect(stream.isAdult == 1)
    }

    @Test func `live stream tv archive coercion`() throws {
        let json = Data("""
        {"stream_id": 1, "tv_archive": "1", "tv_archive_duration": "7"}
        """.utf8)
        let stream = try JSONDecoder().decode(XtreamLiveStream.self, from: json)
        #expect(stream.tvArchive == 1)
        #expect(stream.tvArchiveDuration == 7)
    }

    // MARK: - XtreamVODStream rating coercion edge cases

    @Test func `vod stream rating as double`() throws {
        let json = Data("""
        {"stream_id": 1, "rating": 6.5, "rating_5based": 3.2}
        """.utf8)
        let stream = try JSONDecoder().decode(XtreamVODStream.self, from: json)
        #expect(stream.rating == 6.5)
        #expect(stream.rating5Based == 3.2)
    }

    @Test func `vod stream rating as string`() throws {
        let json = Data("""
        {"stream_id": 1, "rating": "7.0", "rating_5based": "3.5"}
        """.utf8)
        let stream = try JSONDecoder().decode(XtreamVODStream.self, from: json)
        #expect(stream.rating == 7.0)
        #expect(stream.rating5Based == 3.5)
    }

    @Test func `vod stream missing rating defaults to zero`() throws {
        let json = Data("""
        {"stream_id": 1}
        """.utf8)
        let stream = try JSONDecoder().decode(XtreamVODStream.self, from: json)
        #expect(stream.rating == 0.0)
        #expect(stream.rating5Based == 0.0)
    }

    @Test func `vod stream is adult int coercion`() throws {
        let json = Data("""
        {"stream_id": 1, "is_adult": "1"}
        """.utf8)
        let stream = try JSONDecoder().decode(XtreamVODStream.self, from: json)
        #expect(stream.isAdult == 1)
    }

    @Test func `vod stream category ID as int`() throws {
        let json = Data("""
        {"stream_id": 1, "category_id": 99}
        """.utf8)
        let stream = try JSONDecoder().decode(XtreamVODStream.self, from: json)
        #expect(stream.categoryId == "99")
    }

    // MARK: - XtreamVODMetadata duration coercion

    @Test func `vod metadata duration as string`() throws {
        let json = Data("""
        {"duration_secs": "3600"}
        """.utf8)
        let meta = try JSONDecoder().decode(XtreamVODMetadata.self, from: json)
        #expect(meta.durationSecs == 3600)
    }

    @Test func `vod metadata tmdb as int`() throws {
        let json = Data("""
        {"tmdb_id": 12345}
        """.utf8)
        let meta = try JSONDecoder().decode(XtreamVODMetadata.self, from: json)
        #expect(meta.tmdbId == "12345")
    }

    // MARK: - XtreamSeries category_id coercion

    @Test func `series category ID as int`() throws {
        let json = Data("""
        {"series_id": 1, "category_id": 42}
        """.utf8)
        let series = try JSONDecoder().decode(XtreamSeries.self, from: json)
        #expect(series.categoryId == "42")
    }

    @Test func `series category ID as string`() throws {
        let json = Data("""
        {"series_id": 1, "category_id": "42"}
        """.utf8)
        let series = try JSONDecoder().decode(XtreamSeries.self, from: json)
        #expect(series.categoryId == "42")
    }

    // MARK: - XtreamAuthResponse

    @Test func `auth response decodes partial data`() throws {
        let json = Data("""
        {
            "user_info": {"username": "test"},
            "server_info": {"url": "example.com"}
        }
        """.utf8)
        let response = try JSONDecoder().decode(XtreamAuthResponse.self, from: json)
        #expect(response.userInfo.username == "test")
        #expect(response.serverInfo.url == "example.com")
    }

    @Test func `server info properties`() throws {
        let json = Data("""
        {
            "user_info": {},
            "server_info": {
                "url": "example.com",
                "port": "8080",
                "https_port": "443",
                "server_protocol": "http",
                "timezone": "UTC",
                "timestamp_now": 1700000000,
                "time_now": "2024-01-01 00:00:00"
            }
        }
        """.utf8)
        let response = try JSONDecoder().decode(XtreamAuthResponse.self, from: json)
        let server = response.serverInfo
        #expect(server.port == "8080")
        #expect(server.httpsPort == "443")
        #expect(server.serverProtocol == "http")
        #expect(server.timezone == "UTC")
        #expect(server.timestampNow == 1_700_000_000)
        #expect(server.timeNow == "2024-01-01 00:00:00")
    }

    @Test func `auth response decodes numeric fields sent as numbers`() throws {
        // Real panels routinely send ports / dates / counters as numbers where
        // others send strings — the auth response must accept both.
        let json = Data("""
        {
            "user_info": {
                "username": "test",
                "exp_date": 1770000000,
                "is_trial": 0,
                "active_cons": 1,
                "max_connections": 2
            },
            "server_info": {
                "url": "example.com",
                "port": 8080,
                "https_port": 443,
                "timestamp_now": "1700000000"
            }
        }
        """.utf8)
        let response = try JSONDecoder().decode(XtreamAuthResponse.self, from: json)
        #expect(response.userInfo.expDate == "1770000000")
        #expect(response.userInfo.isTrial == "0")
        #expect(response.userInfo.activeCons == "1")
        #expect(response.userInfo.maxConnections == "2")
        #expect(response.serverInfo.port == "8080")
        #expect(response.serverInfo.httpsPort == "443")
        #expect(response.serverInfo.timestampNow == 1_700_000_000)
    }

    // MARK: - XtreamCategory coercion

    @Test func `category decodes int id and string parent id`() throws {
        let json = Data("""
        {"category_id": 42, "category_name": "Movies", "parent_id": "7"}
        """.utf8)
        let category = try JSONDecoder().decode(XtreamCategory.self, from: json)
        #expect(category.categoryId == "42")
        #expect(category.categoryName == "Movies")
        #expect(category.parentId == 7)
    }

    @Test func `category without id fails alone but is dropped from a list`() throws {
        let missingId = Data("""
        {"category_name": "Orphan"}
        """.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(XtreamCategory.self, from: missingId)
        }

        let json = Data("""
        [
            {"category_id": "1", "category_name": "Keep"},
            {"category_name": "Drop"},
            {"category_id": 2, "category_name": "Keep too"}
        ]
        """.utf8)
        let list = try JSONDecoder().decode(XtreamList<XtreamCategory>.self, from: json)
        #expect(list.items.map(\.categoryId) == ["1", "2"])
    }

    // MARK: - XtreamList payload shapes

    @Test func `list decodes index-keyed object payload`() throws {
        let json = Data("""
        {
            "10": {"category_id": "b", "category_name": "Second"},
            "2": {"category_id": "a", "category_name": "First"}
        }
        """.utf8)
        let list = try JSONDecoder().decode(XtreamList<XtreamCategory>.self, from: json)
        #expect(list.items.map(\.categoryId) == ["a", "b"])
    }

    @Test func `list decodes empty array`() throws {
        let list = try JSONDecoder().decode(XtreamList<XtreamCategory>.self, from: Data("[]".utf8))
        #expect(list.items.isEmpty)
    }

    @Test func `list with only undecodable entries throws instead of returning empty`() {
        // An {"error": …} body must not sync as "zero items" — that would let
        // the prune pass wipe the catalog.
        let json = Data("""
        {"error": "account expired"}
        """.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(XtreamList<XtreamCategory>.self, from: json)
        }
    }

    // MARK: - XtreamSeriesInfoResponse episode payload shapes

    @Test func `series info decodes flat episode array`() throws {
        let json = Data("""
        {
            "info": {"name": "Show", "rating": 8},
            "episodes": [
                {"id": "1", "episode_num": 1, "season": 2},
                {"id": "2", "episode_num": 2, "season": 2}
            ]
        }
        """.utf8)
        let response = try JSONDecoder().decode(XtreamSeriesInfoResponse.self, from: json)
        #expect(response.info?.rating == "8")
        #expect(response.episodes?["2"]?.map(\.id) == ["1", "2"])
    }

    @Test func `series info decodes array of season arrays`() throws {
        let json = Data("""
        {
            "episodes": [
                [{"id": "1", "season": 1}],
                [{"id": "2", "season": 2}, {"id": "3", "season": 2}]
            ]
        }
        """.utf8)
        let response = try JSONDecoder().decode(XtreamSeriesInfoResponse.self, from: json)
        #expect(response.episodes?["1"]?.map(\.id) == ["1"])
        #expect(response.episodes?["2"]?.map(\.id) == ["2", "3"])
    }

    @Test func `series info tolerates empty episodes array`() throws {
        let json = Data("""
        {"info": {"name": "Show"}, "episodes": []}
        """.utf8)
        let response = try JSONDecoder().decode(XtreamSeriesInfoResponse.self, from: json)
        #expect(response.episodes?.isEmpty != false)
    }
}

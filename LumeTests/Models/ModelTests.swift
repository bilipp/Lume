import Foundation
@testable import Lume
import SwiftData
import Testing

struct ModelTests {
    // MARK: - ModelContainer Setup

    @Test func `model container creates successfully`() throws {
        let container = try makeTestContainer()
        let entityNames = container.schema.entities.map(\.name)
        #expect(entityNames.contains("Playlist"))
        #expect(entityNames.contains("Category"))
        #expect(entityNames.contains("Movie"))
        #expect(entityNames.contains("Series"))
        #expect(entityNames.contains("Episode"))
        #expect(entityNames.contains("LiveStream"))
        #expect(entityNames.contains("EPGListing"))
    }

    // MARK: - Category

    @Test func `category ID construction`() {
        let playlist = Playlist(name: "P", serverURL: "http://x.com", username: "u", password: "p")
        let category = Lume.Category(apiId: "42", name: "Action", parentId: 0, type: .vod, playlist: playlist)
        let expectedPrefix = "\(playlist.id.uuidString)-vod-42"
        #expect(category.id == expectedPrefix)
        #expect(category.apiId == "42")
        #expect(category.name == "Action")
        #expect(category.type == .vod)
        #expect(category.playlist?.id == playlist.id)
    }

    @Test func `category type round trip`() {
        let playlist = Playlist(name: "P", serverURL: "http://x.com", username: "u", password: "p")
        let live = Lume.Category(apiId: "1", name: "Live", parentId: 0, type: .live, playlist: playlist)
        #expect(live.type == .live)
        #expect(live.typeRaw == "live")

        live.type = .series
        #expect(live.type == .series)
        #expect(live.typeRaw == "series")
    }

    @Test func `category upsert via unique attribute`() throws {
        let container = try makeTestContainer()
        let playlist = Playlist(name: "P", serverURL: "http://x.com", username: "u", password: "p")

        let ctx1 = ModelContext(container)
        ctx1.autosaveEnabled = false
        let cat = Lume.Category(apiId: "1", name: "Original", parentId: 0, type: .vod, playlist: playlist)
        ctx1.insert(cat)
        try ctx1.save()

        let ctx2 = ModelContext(container)
        ctx2.autosaveEnabled = false
        let cat2 = Lume.Category(apiId: "1", name: "Updated", parentId: 0, type: .vod, playlist: playlist)
        cat2.id = cat.id // Same unique ID
        ctx2.insert(cat2)
        try ctx2.save()

        let expectedApiId = "1"
        let fetch = FetchDescriptor<Lume.Category>(predicate: #Predicate { $0.apiId == expectedApiId })
        let results = try ctx2.fetch(fetch)
        #expect(results.count == 1)
    }

    // MARK: - Movie

    @Test func `movie download status round trip`() {
        let movie = Movie(id: "m-1", streamId: 1, name: "Test")
        #expect(movie.downloadStatus == nil)

        movie.downloadStatus = .downloading
        #expect(movie.downloadStatus == .downloading)
        #expect(movie.downloadStatusRaw == "downloading")

        movie.downloadStatus = .completed
        #expect(movie.downloadStatus == .completed)
    }

    @Test func `movie favorite and watch tracking`() {
        let movie = Movie(id: "m-2", streamId: 2, name: "Tracked")
        #expect(movie.isFavorite == false)
        #expect(movie.isWatched == false)
        #expect(movie.watchProgress == 0)

        movie.isFavorite = true
        #expect(movie.isFavorite == true)

        movie.watchProgress = 500
        movie.isWatched = true
        #expect(movie.watchProgress == 500)
        #expect(movie.isWatched == true)
    }

    @Test func `movie TMDB coercion`() {
        let movie = Movie(id: "m-3", streamId: 3, name: "TMDB", tmdb: "12345")
        movie.tmdbId = Int(movie.tmdb ?? "")
        #expect(movie.tmdbId == 12345)
    }

    @Test func `movie TMDB enrichment fields`() {
        let movie = Movie(id: "m-4", streamId: 4, name: "Enriched")
        movie.backdropPath = "/backdrop.jpg"
        movie.tagline = "A tagline"
        movie.contentRating = "PG-13"
        movie.tmdbEnrichedAt = Date()
        movie.similarTMDBIds = [1, 2, 3]
        movie.collectionId = 42
        movie.collectionName = "Collection"
        movie.collectionPosterPath = "/poster.jpg"
        movie.collectionBackdropPath = "/back.jpg"
        #expect(movie.backdropPath == "/backdrop.jpg")
        #expect(movie.tagline == "A tagline")
        #expect(movie.contentRating == "PG-13")
        #expect(movie.tmdbEnrichedAt != nil)
        #expect(movie.similarTMDBIds == [1, 2, 3])
        #expect(movie.collectionId == 42)
        #expect(movie.collectionName == "Collection")
    }

    @Test func `movie watch tracking date fields`() {
        let movie = Movie(id: "m-5", streamId: 5, name: "Dates")
        movie.lastWatchedDate = Date(timeIntervalSince1970: 1_700_000_000)
        movie.addedToWatchlistDate = Date(timeIntervalSince1970: 1_700_000_100)
        movie.traktId = "trakt-123"
        movie.localFileURL = "/path/to/file.mp4"
        movie.downloadedAt = Date()
        #expect(movie.lastWatchedDate?.timeIntervalSince1970 == 1_700_000_000)
        #expect(movie.addedToWatchlistDate?.timeIntervalSince1970 == 1_700_000_100)
        #expect(movie.traktId == "trakt-123")
        #expect(movie.localFileURL == "/path/to/file.mp4")
        #expect(movie.downloadedAt != nil)
    }

    // MARK: - Episode

    @Test func `episode download status round trip`() {
        let episode = Episode(id: "e-1", episodeId: "1", title: "Ep1",
                              containerExtension: "mp4", seasonNum: 1, episodeNum: 1)
        #expect(episode.downloadStatus == nil)

        episode.downloadStatus = .failed
        #expect(episode.downloadStatus == .failed)
        #expect(episode.downloadStatusRaw == "failed")
    }

    @Test func `episode watch progress`() {
        let episode = Episode(id: "e-2", episodeId: "2", title: "Ep2",
                              containerExtension: "mkv", seasonNum: 2, episodeNum: 3)
        #expect(episode.watchProgress == 0)
        episode.watchProgress = 3600
        #expect(episode.watchProgress == 3600)
    }

    @Test func `episode is watched`() {
        let episode = Episode(id: "e-3", episodeId: "3", title: "Ep3",
                              containerExtension: "mp4", seasonNum: 1, episodeNum: 5)
        #expect(episode.isWatched == false)
        episode.isWatched = true
        #expect(episode.isWatched == true)
    }

    @Test func `episode all download statuses`() {
        let episode = Episode(id: "e-4", episodeId: "4", title: "Ep4",
                              containerExtension: "mkv", seasonNum: 1, episodeNum: 1)
        episode.downloadStatus = .pending
        #expect(episode.downloadStatus == .pending)
        episode.downloadStatus = .downloading
        #expect(episode.downloadStatus == .downloading)
        episode.downloadStatus = .completed
        #expect(episode.downloadStatus == .completed)
    }

    @Test func `episode metadata fields`() {
        let episode = Episode(id: "e-5", episodeId: "5", title: "Ep5",
                              containerExtension: "mp4", seasonNum: 1, episodeNum: 2)
        episode.durationSecs = 1800
        episode.movieImage = "http://example.com/ep.jpg"
        episode.plot = "An episode plot"
        episode.rating = 8.5
        episode.airDate = "2024-01-15"
        episode.directSource = "http://example.com/direct"
        episode.added = "1700000000"
        #expect(episode.durationSecs == 1800)
        #expect(episode.movieImage == "http://example.com/ep.jpg")
        #expect(episode.plot == "An episode plot")
        #expect(episode.rating == 8.5)
        #expect(episode.airDate == "2024-01-15")
        #expect(episode.directSource == "http://example.com/direct")
        #expect(episode.added == "1700000000")
    }

    @Test func `episode series relationship`() {
        let series = Series(id: "s-1", seriesId: 1, name: "Test Series")
        let episode = Episode(id: "e-6", episodeId: "6", title: "Ep6",
                              containerExtension: "mp4", seasonNum: 1, episodeNum: 1,
                              series: series)
        #expect(episode.series?.id == "s-1")
        #expect(episode.series?.name == "Test Series")
    }

    // MARK: - Playlist

    @Test func `playlist sync status round trip`() {
        let playlist = Playlist(name: "Test", serverURL: "http://x.com", username: "u", password: "p")
        #expect(playlist.syncStatus == .idle)
        #expect(playlist.syncStatusRaw == "idle")

        playlist.syncStatus = .syncing
        #expect(playlist.syncStatus == .syncing)

        playlist.syncStatus = .error
        #expect(playlist.syncStatus == .error)
    }

    @Test func `playlist default values`() {
        let playlist = Playlist(name: "Test", serverURL: "http://x.com", username: "u", password: "p")
        #expect(playlist.syncEnabled == true)
        #expect(playlist.categories.isEmpty)
        #expect(playlist.addedAt.timeIntervalSinceNow < 1) // Created recently
    }

    // MARK: - Series

    @Test func `series default values`() {
        let series = Series(id: "s-1", seriesId: 1, name: "Series")
        #expect(series.isFavorite == false)
        #expect(series.episodes.isEmpty)
    }

    // MARK: - EPGListing

    @Test func `epg listing creation`() {
        let start = Date()
        let end = start.addingTimeInterval(3600)
        let listing = EPGListing(
            id: "epg-1",
            channelId: "channel-1",
            title: "News at Six",
            listingDescription: "The evening news broadcast",
            start: start,
            end: end
        )
        #expect(listing.id == "epg-1")
        #expect(listing.channelId == "channel-1")
        #expect(listing.title == "News at Six")
        #expect(listing.listingDescription == "The evening news broadcast")
        #expect(listing.start == start)
        #expect(listing.end == end)
    }

    @Test func `epg listing channelId matches stream`() {
        let stream = LiveStream(id: "l-1", streamId: 1, name: "Channel", epgChannelId: "channel-1")
        let listing = EPGListing(
            id: "epg-1",
            channelId: "channel-1",
            title: "News",
            listingDescription: "",
            start: Date(),
            end: Date().addingTimeInterval(3600)
        )
        #expect(listing.channelId == stream.epgChannelId)
    }

    // MARK: - CastMember

    @Test func `cast member creation`() {
        let movie = Movie(id: "m-1", streamId: 1, name: "Film")
        let cast = CastMember(
            id: "m-1-cast-0",
            tmdbPersonId: 123,
            name: "Actor Name",
            role: "Lead Role",
            profilePath: "/abc.jpg",
            order: 0,
            movie: movie
        )
        #expect(cast.id == "m-1-cast-0")
        #expect(cast.tmdbPersonId == 123)
        #expect(cast.name == "Actor Name")
        #expect(cast.role == "Lead Role")
        #expect(cast.profilePath == "/abc.jpg")
        #expect(cast.order == 0)
        #expect(cast.movie?.id == "m-1")
        #expect(cast.series == nil)
    }

    @Test func `cast member default values`() {
        let cast = CastMember(
            id: "s-1-cast-0",
            tmdbPersonId: 456,
            name: "Another Actor"
        )
        #expect(cast.role == nil)
        #expect(cast.profilePath == nil)
        #expect(cast.order == 0)
        #expect(cast.movie == nil)
        #expect(cast.series == nil)
    }

    @Test func `cast member can belong to series`() {
        let series = Series(id: "s-1", seriesId: 1, name: "Show")
        let cast = CastMember(
            id: "s-1-cast-0",
            tmdbPersonId: 789,
            name: "TV Actor",
            role: "Main Character",
            order: 1,
            series: series
        )
        #expect(cast.series?.id == "s-1")
        #expect(cast.movie == nil)
        #expect(cast.order == 1)
    }

    // MARK: - Movie Ordered Cast

    @Test func `movie ordered cast sorts by order`() {
        let movie = Movie(id: "m-1", streamId: 1, name: "Film")
        let cast1 = CastMember(id: "m-1-cast-0", tmdbPersonId: 1, name: "Second", order: 1, movie: movie)
        let cast2 = CastMember(id: "m-1-cast-1", tmdbPersonId: 2, name: "First", order: 0, movie: movie)
        movie.castMembers = [cast1, cast2]
        let ordered = movie.orderedCast
        #expect(ordered[0].name == "First")
        #expect(ordered[1].name == "Second")
    }

    @Test func `series ordered cast sorts by order`() {
        let series = Series(id: "s-1", seriesId: 1, name: "Show")
        let cast1 = CastMember(id: "s-1-cast-0", tmdbPersonId: 1, name: "Second", order: 1, series: series)
        let cast2 = CastMember(id: "s-1-cast-1", tmdbPersonId: 2, name: "First", order: 0, series: series)
        series.castMembers = [cast1, cast2]
        let ordered = series.orderedCast
        #expect(ordered[0].name == "First")
        #expect(ordered[1].name == "Second")
    }

    // MARK: - LiveStream

    @Test func `live stream default values`() {
        let stream = LiveStream(id: "l-1", streamId: 1, name: "Channel")
        #expect(stream.isFavorite == false)
        #expect(stream.tvArchive == 0)
        #expect(stream.tvArchiveDuration == 0)
    }

    @Test func `live stream full init`() {
        let stream = LiveStream(
            id: "l-2",
            streamId: 2,
            name: "News Channel",
            streamIcon: "http://example.com/icon.png",
            epgChannelId: "BBC1",
            added: "1700000000",
            customSid: "sid-123",
            tvArchive: 1,
            tvArchiveDuration: 7,
            isAdult: 0,
            num: 1,
            categoryId: "cat-1"
        )
        #expect(stream.streamIcon == "http://example.com/icon.png")
        #expect(stream.epgChannelId == "BBC1")
        #expect(stream.added == "1700000000")
        #expect(stream.customSid == "sid-123")
        #expect(stream.tvArchive == 1)
        #expect(stream.tvArchiveDuration == 7)
        #expect(stream.categoryId == "cat-1")
        #expect(stream.customOrder == nil)
    }

    @Test func `live stream favorite`() {
        let stream = LiveStream(id: "l-3", streamId: 3, name: "Fav Channel")
        stream.isFavorite = true
        stream.customOrder = 5
        stream.lastWatchedDate = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(stream.isFavorite == true)
        #expect(stream.customOrder == 5)
        #expect(stream.lastWatchedDate?.timeIntervalSince1970 == 1_700_000_000)
    }

    // MARK: - Enums

    @Test func `category type raw values`() {
        #expect(CategoryType.live.rawValue == "live")
        #expect(CategoryType.vod.rawValue == "vod")
        #expect(CategoryType.series.rawValue == "series")
    }

    @Test func `sync status raw values`() {
        #expect(SyncStatus.idle.rawValue == "idle")
        #expect(SyncStatus.syncing.rawValue == "syncing")
        #expect(SyncStatus.error.rawValue == "error")
    }

    @Test func `download status all cases`() {
        #expect(DownloadStatus.pending.rawValue == "pending")
        #expect(DownloadStatus.downloading.rawValue == "downloading")
        #expect(DownloadStatus.completed.rawValue == "completed")
        #expect(DownloadStatus.failed.rawValue == "failed")
    }
}

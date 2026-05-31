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
            epgId: "channel-1",
            title: "News at Six",
            listingDescription: "The evening news broadcast",
            start: start,
            end: end
        )
        #expect(listing.id == "epg-1")
        #expect(listing.epgId == "channel-1")
        #expect(listing.title == "News at Six")
        #expect(listing.listingDescription == "The evening news broadcast")
        #expect(listing.start == start)
        #expect(listing.end == end)
        #expect(listing.liveStream == nil)
    }

    @Test func `epg listing links to live stream`() {
        let stream = LiveStream(id: "l-1", streamId: 1, name: "Channel")
        let listing = EPGListing(
            id: "epg-1",
            epgId: "channel-1",
            title: "News",
            listingDescription: "",
            start: Date(),
            end: Date().addingTimeInterval(3600),
            liveStream: stream
        )
        #expect(listing.liveStream?.id == "l-1")
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
        #expect(stream.epgListings.isEmpty)
        #expect(stream.tvArchive == 0)
        #expect(stream.tvArchiveDuration == 0)
    }
}

//
//  ContentSyncFieldApplicationTests.swift
//  LumeTests
//
//  Guards the dirty-checked provider-field application: an unchanged re-sync
//  must leave the context clean, while every real provider change — including
//  nil ⇄ "" — must still be written and every user-state field must survive.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

/// Shared across the movie/live-stream suites below and the series suite in
/// `ContentSyncSeriesFieldApplicationTests`; split across types and files only
/// to stay under SwiftLint's type-body and file-length limits.
enum FieldFixtures {
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self,
            Lume.Category.self,
            LiveStream.self,
            Movie.self,
            Series.self,
            Episode.self,
            CastMember.self,
            EPGListing.self,
            EPGSource.self
        ])
        // `cloudKitDatabase: .none` is required: the catalog uses `@Attribute(.unique)`,
        // which CloudKit forbids. The default `.automatic` mirrors to CloudKit on a
        // signed/entitled test host and fails the load with `loadIssueModelContainer`.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// The DTOs are decode-only (no memberwise init), so every fixture is a
    /// provider payload verbatim.
    static func decodeMovie(_ json: String) throws -> XtreamVODStream {
        try JSONDecoder().decode(XtreamVODStream.self, from: Data(json.utf8))
    }

    static func decodeLiveStream(_ json: String) throws -> XtreamLiveStream {
        try JSONDecoder().decode(XtreamLiveStream.self, from: Data(json.utf8))
    }

    static func decodeSeries(_ json: String) throws -> XtreamSeries {
        try JSONDecoder().decode(XtreamSeries.self, from: Data(json.utf8))
    }

    static func movieJSON(
        name: String = "The Matrix",
        streamIcon: String = "\"https://image.tmdb.org/t/p/w600_and_h900_bestv2/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg\"",
        rating: String = "\"8.7\"",
        ratingFiveBased: String = "4.35",
        added: String = "\"1690000000\"",
        containerExtension: String = "\"mkv\"",
        tmdb: String = "\"603\"",
        categoryId: String = "\"77\"",
        num: Int = 1,
        isAdult: String = "\"0\""
    ) -> String {
        """
        {"num":\(num),"name":"\(name)","stream_type":"movie","stream_id":12345,
         "stream_icon":\(streamIcon),"rating":\(rating),"rating_5based":\(ratingFiveBased),
         "added":\(added),"is_adult":\(isAdult),"category_id":\(categoryId),
         "container_extension":\(containerExtension),"custom_sid":null,"direct_source":"",
         "tmdb":\(tmdb)}
        """
    }

    static func liveJSON(
        name: String = "BBC One HD",
        streamIcon: String = "\"http://provider.example.com/logos/bbc1.png\"",
        epgChannelId: String = "\"bbc.one.uk\"",
        added: String = "\"1650000000\"",
        customSid: String = "null",
        tvArchive: Int = 1,
        tvArchiveDuration: Int = 7,
        isAdult: Int = 0,
        categoryId: String = "\"12\"",
        num: Int = 3
    ) -> String {
        """
        {"num":\(num),"name":"\(name)","stream_type":"live","stream_id":9876,
         "stream_icon":\(streamIcon),"epg_channel_id":\(epgChannelId),"added":\(added),
         "is_adult":\(isAdult),"category_id":\(categoryId),"custom_sid":\(customSid),
         "tv_archive":\(tvArchive),"tv_archive_duration":\(tvArchiveDuration),
         "direct_source":""}
        """
    }

    /// Shaped after the measured provider's `get_series` rows: `rating` and
    /// `rating_5based` arrive as strings, `backdrop_path` as an array the DTO
    /// ignores, and `tmdb` is absent entirely for most rows.
    static func seriesJSON(
        name: String = "Acapulco",
        cover: String = "\"https://image.tmdb.org/t/p/w600_and_h900_bestv2/lU0RlcfBx6y0FSmEAq61ztjMgjt.jpg\"",
        plot: String = "\"In 1984, Maximo Gallardo lands the job of a lifetime at Las Colinas.\"",
        cast: String = "\"Eugenio Derbez, Enrique Arrizon, Raphael Alejandro\"",
        director: String = "\"Austin Winsberg, Jason Shuman\"",
        genre: String = "\"Comedy / Drama\"",
        releaseDate: String = "\"2021-10-08\"",
        lastModified: String = "\"1776621142\"",
        rating: String = "\"7\"",
        ratingFiveBased: String = "\"1.4\"",
        categoryId: String = "\"434\"",
        tmdb: String = "\"90881\"",
        num: Int = 1
    ) -> String {
        """
        {"num":\(num),"name":"\(name)","series_id":13855,"cover":\(cover),
         "plot":\(plot),"cast":\(cast),"director":\(director),"genre":\(genre),
         "releaseDate":\(releaseDate),"last_modified":\(lastModified),
         "rating":\(rating),"rating_5based":\(ratingFiveBased),
         "backdrop_path":["https://image.tmdb.org/t/p/w1280/1vI6V8tyV7HDQYLlhn67mlLHoWJ.jpg"],
         "youtube_trailer":"e8YKi_05emo","episode_run_time":"0",
         "category_id":\(categoryId),"category_ids":[434],"tmdb":\(tmdb)}
        """
    }
}

struct ContentSyncMovieFieldTests {
    @Test func `changed movie fields are written`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-vod-"
        let movieId = "\(playlistId.uuidString)-movie-12345"

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let movie = Movie(id: movieId, streamId: 12345, name: "Stale name")
        movie.rating = 1.0
        movie.categoryId = prefix + "1"
        context.insert(movie)
        try context.save()

        let dto = try FieldFixtures.decodeMovie(FieldFixtures.movieJSON())
        await manager.applyMovieFields(from: dto, to: movie, playlistPrefix: prefix)

        #expect(context.hasChanges, "A changed provider payload must dirty the context")
        #expect(movie.name == "The Matrix")
        #expect(movie.streamIcon == "https://image.tmdb.org/t/p/w600_and_h900_bestv2/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg")
        #expect(movie.rating == 8.7)
        #expect(movie.rating5Based == 4.35)
        #expect(movie.added == "1690000000")
        #expect(movie.containerExtension == "mkv")
        #expect(movie.tmdb == "603")
        #expect(movie.tmdbId == 603)
        #expect(movie.num == 1)
        #expect(movie.isAdult == 0)
        #expect(movie.categoryId == prefix + "77")
    }

    @Test func `unchanged movie batch leaves the context clean`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-vod-"
        let movieId = "\(playlistId.uuidString)-movie-12345"
        let dto = try FieldFixtures.decodeMovie(FieldFixtures.movieJSON())

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Movie(id: movieId, streamId: 12345, name: "")
        firstSync.insert(inserted)
        await manager.applyMovieFields(from: dto, to: inserted, playlistPrefix: prefix)
        try firstSync.save()

        // Second sync of the identical payload, through a fresh context exactly
        // as the batch loop builds one.
        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        ).first)
        await manager.applyMovieFields(from: dto, to: stored, playlistPrefix: prefix)

        #expect(!reSync.hasChanges, "An unchanged payload must not dirty the context — the save is then skipped")
    }

    @Test func `numeric movie fields round-trip through both provider representations`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-vod-"
        let movieId = "\(playlistId.uuidString)-movie-12345"

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Movie(id: movieId, streamId: 12345, name: "")
        firstSync.insert(inserted)
        try await manager.applyMovieFields(
            from: FieldFixtures.decodeMovie(FieldFixtures.movieJSON(rating: "\"8.7\"", ratingFiveBased: "4.35")),
            to: inserted,
            playlistPrefix: prefix
        )
        try firstSync.save()

        // Same values, sent as a JSON number and a JSON string respectively —
        // the lenient decoders must land on the identical Double, so nothing is
        // rewritten.
        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        ).first)
        try await manager.applyMovieFields(
            from: FieldFixtures.decodeMovie(FieldFixtures.movieJSON(rating: "8.7", ratingFiveBased: "\"4.35\"")),
            to: stored,
            playlistPrefix: prefix
        )

        #expect(!reSync.hasChanges)
        #expect(stored.rating == 8.7)
        #expect(stored.rating5Based == 4.35)
    }

    @Test func `movie nil to empty string is written`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-vod-"
        let movieId = "\(playlistId.uuidString)-movie-12345"

        // Baseline sync: the provider omitted these keys, so they store as nil.
        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Movie(id: movieId, streamId: 12345, name: "")
        firstSync.insert(inserted)
        try await manager.applyMovieFields(
            from: FieldFixtures.decodeMovie(FieldFixtures.movieJSON(streamIcon: "null", containerExtension: "null", tmdb: "null")),
            to: inserted,
            playlistPrefix: prefix
        )
        try firstSync.save()
        #expect(inserted.streamIcon == nil)

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        ).first)
        try await manager.applyMovieFields(
            from: FieldFixtures.decodeMovie(FieldFixtures.movieJSON(streamIcon: "\"\"", containerExtension: "\"\"", tmdb: "\"\"")),
            to: stored,
            playlistPrefix: prefix
        )

        #expect(reSync.hasChanges, "nil → \"\" is a real change and must be written")
        #expect(stored.streamIcon == "")
        #expect(stored.containerExtension == "")
        #expect(stored.tmdb == "")
        #expect(stored.tmdbId == nil, "An unparseable tmdb must leave the resolved id alone")
    }

    @Test func `movie empty string to nil is written`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-vod-"
        let movieId = "\(playlistId.uuidString)-movie-12345"

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Movie(id: movieId, streamId: 12345, name: "")
        firstSync.insert(inserted)
        try await manager.applyMovieFields(
            from: FieldFixtures.decodeMovie(FieldFixtures.movieJSON(streamIcon: "\"\"", added: "\"\"")),
            to: inserted,
            playlistPrefix: prefix
        )
        try firstSync.save()
        #expect(inserted.streamIcon == "")

        // The provider dropped both keys: the lenient decoders yield nil.
        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        ).first)
        try await manager.applyMovieFields(
            from: FieldFixtures.decodeMovie(FieldFixtures.movieJSON(streamIcon: "null", added: "null")),
            to: stored,
            playlistPrefix: prefix
        )

        #expect(reSync.hasChanges, "\"\" → nil is a real change and must be written")
        #expect(stored.streamIcon == nil)
        #expect(stored.added == nil)
    }

    @Test func `movie empty strings on both sides stay clean`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-vod-"
        let movieId = "\(playlistId.uuidString)-movie-12345"
        let dto = try FieldFixtures.decodeMovie(FieldFixtures.movieJSON(streamIcon: "\"\"", tmdb: "\"\""))

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Movie(id: movieId, streamId: 12345, name: "")
        firstSync.insert(inserted)
        await manager.applyMovieFields(from: dto, to: inserted, playlistPrefix: prefix)
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        ).first)
        #expect(stored.streamIcon == "")
        await manager.applyMovieFields(from: dto, to: stored, playlistPrefix: prefix)

        #expect(!reSync.hasChanges)
    }

    @Test func `a movie payload without a category leaves the stored category alone`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-vod-"
        let movieId = "\(playlistId.uuidString)-movie-12345"

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Movie(id: movieId, streamId: 12345, name: "")
        firstSync.insert(inserted)
        try await manager.applyMovieFields(from: FieldFixtures.decodeMovie(FieldFixtures.movieJSON()), to: inserted, playlistPrefix: prefix)
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        ).first)
        try await manager.applyMovieFields(
            from: FieldFixtures.decodeMovie(FieldFixtures.movieJSON(categoryId: "null")),
            to: stored,
            playlistPrefix: prefix
        )

        #expect(stored.categoryId == prefix + "77")
        #expect(!reSync.hasChanges)
    }

    @Test func `movie user state and enrichment survive a re-sync`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-vod-"
        let movieId = "\(playlistId.uuidString)-movie-12345"
        let watched = Date(timeIntervalSince1970: 1_000_000)
        let addedToWatchlist = Date(timeIntervalSince1970: 2_000_000)
        let enriched = Date(timeIntervalSince1970: 3_000_000)

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = Movie(id: movieId, streamId: 12345, name: "")
        firstSync.insert(inserted)
        try await manager.applyMovieFields(from: FieldFixtures.decodeMovie(FieldFixtures.movieJSON()), to: inserted, playlistPrefix: prefix)
        inserted.isFavorite = true
        inserted.favoriteOrder = 4
        inserted.watchProgress = 1234
        inserted.isWatched = true
        inserted.lastWatchedDate = watched
        inserted.addedToWatchlistDate = addedToWatchlist
        inserted.plot = "TMDB plot"
        inserted.genre = "Science Fiction"
        inserted.backdropPath = "/backdrop.jpg"
        inserted.tmdbEnrichedAt = enriched
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        ).first)
        try await manager.applyMovieFields(
            from: FieldFixtures.decodeMovie(FieldFixtures.movieJSON(name: "The Matrix (Remastered)")),
            to: stored,
            playlistPrefix: prefix
        )
        try reSync.save()

        let verify = ModelContext(container)
        let result = try #require(try verify.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        ).first)
        #expect(result.name == "The Matrix (Remastered)", "The provider rename must land")
        #expect(result.isFavorite)
        #expect(result.favoriteOrder == 4)
        #expect(result.watchProgress == 1234)
        #expect(result.isWatched)
        #expect(result.lastWatchedDate == watched)
        #expect(result.addedToWatchlistDate == addedToWatchlist)
        #expect(result.plot == "TMDB plot")
        #expect(result.genre == "Science Fiction")
        #expect(result.backdropPath == "/backdrop.jpg")
        #expect(result.tmdbEnrichedAt == enriched)
    }
}

struct ContentSyncLiveStreamFieldTests {
    @Test func `changed live stream fields are written`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-live-"
        let streamId = "\(playlistId.uuidString)-live-9876"

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let stream = LiveStream(id: streamId, streamId: 9876, name: "Stale name")
        context.insert(stream)
        try context.save()

        try await manager.applyLiveStreamFields(from: FieldFixtures.decodeLiveStream(FieldFixtures.liveJSON()), to: stream, playlistPrefix: prefix)

        #expect(context.hasChanges)
        #expect(stream.name == "BBC One HD")
        #expect(stream.streamIcon == "http://provider.example.com/logos/bbc1.png")
        #expect(stream.epgChannelId == "bbc.one.uk")
        #expect(stream.added == "1650000000")
        #expect(stream.customSid == nil)
        #expect(stream.tvArchive == 1)
        #expect(stream.tvArchiveDuration == 7)
        #expect(stream.isAdult == 0)
        #expect(stream.num == 3)
        #expect(stream.categoryId == prefix + "12")
    }

    @Test func `unchanged live stream batch leaves the context clean`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-live-"
        let streamId = "\(playlistId.uuidString)-live-9876"
        let dto = try FieldFixtures.decodeLiveStream(FieldFixtures.liveJSON())

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = LiveStream(id: streamId, streamId: 9876, name: "")
        firstSync.insert(inserted)
        await manager.applyLiveStreamFields(from: dto, to: inserted, playlistPrefix: prefix)
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == streamId })
        ).first)
        await manager.applyLiveStreamFields(from: dto, to: stored, playlistPrefix: prefix)

        #expect(!reSync.hasChanges, "An unchanged payload must not dirty the context — the save is then skipped")
    }

    @Test func `live stream empty and nil epg ids round-trip both ways`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-live-"
        let streamId = "\(playlistId.uuidString)-live-9876"

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = LiveStream(id: streamId, streamId: 9876, name: "")
        firstSync.insert(inserted)
        try await manager.applyLiveStreamFields(
            from: FieldFixtures.decodeLiveStream(FieldFixtures.liveJSON(streamIcon: "null", epgChannelId: "null")),
            to: inserted,
            playlistPrefix: prefix
        )
        try firstSync.save()
        #expect(inserted.epgChannelId == nil)

        // Most rows in a real payload carry "" here, not null.
        let toEmpty = ModelContext(container)
        toEmpty.autosaveEnabled = false
        let stored = try #require(try toEmpty.fetch(
            FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == streamId })
        ).first)
        try await manager.applyLiveStreamFields(
            from: FieldFixtures.decodeLiveStream(FieldFixtures.liveJSON(streamIcon: "\"\"", epgChannelId: "\"\"")),
            to: stored,
            playlistPrefix: prefix
        )
        #expect(toEmpty.hasChanges, "nil → \"\" is a real change and must be written")
        #expect(stored.epgChannelId == "")
        #expect(stored.streamIcon == "")
        try toEmpty.save()

        let toNil = ModelContext(container)
        toNil.autosaveEnabled = false
        let reFetched = try #require(try toNil.fetch(
            FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == streamId })
        ).first)
        try await manager.applyLiveStreamFields(
            from: FieldFixtures.decodeLiveStream(FieldFixtures.liveJSON(streamIcon: "null", epgChannelId: "null")),
            to: reFetched,
            playlistPrefix: prefix
        )
        #expect(toNil.hasChanges, "\"\" → nil is a real change and must be written")
        #expect(reFetched.epgChannelId == nil)
        #expect(reFetched.streamIcon == nil)
    }

    @Test func `live stream user state survives a re-sync`() async throws {
        let container = try FieldFixtures.makeContainer()
        let manager = ContentSyncManager(modelContainer: container)
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-live-"
        let streamId = "\(playlistId.uuidString)-live-9876"
        let watched = Date(timeIntervalSince1970: 1_500_000)

        let firstSync = ModelContext(container)
        firstSync.autosaveEnabled = false
        let inserted = LiveStream(id: streamId, streamId: 9876, name: "")
        firstSync.insert(inserted)
        try await manager.applyLiveStreamFields(from: FieldFixtures.decodeLiveStream(FieldFixtures.liveJSON()), to: inserted, playlistPrefix: prefix)
        inserted.isFavorite = true
        inserted.favoriteOrder = 2
        inserted.isHidden = true
        inserted.customOrder = 7
        inserted.lastWatchedDate = watched
        try firstSync.save()

        let reSync = ModelContext(container)
        reSync.autosaveEnabled = false
        let stored = try #require(try reSync.fetch(
            FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == streamId })
        ).first)
        try await manager.applyLiveStreamFields(
            from: FieldFixtures.decodeLiveStream(FieldFixtures.liveJSON(name: "BBC One UHD", num: 4)),
            to: stored,
            playlistPrefix: prefix
        )
        try reSync.save()

        let verify = ModelContext(container)
        let result = try #require(try verify.fetch(
            FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == streamId })
        ).first)
        #expect(result.name == "BBC One UHD", "The provider rename must land")
        #expect(result.num == 4)
        #expect(result.isFavorite)
        #expect(result.favoriteOrder == 2)
        #expect(result.isHidden)
        #expect(result.customOrder == 7)
        #expect(result.lastWatchedDate == watched)
    }
}

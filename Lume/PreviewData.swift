import Foundation
import SwiftData
import SwiftUI

enum PreviewData {
    static let samplePlaylistID = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"

    // MARK: - Playlist

    static var samplePlaylist: Playlist {
        let playlist = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "demo", password: "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
        playlist.id = UUID(uuidString: samplePlaylistID)!
        playlist.userStatus = "Active"
        playlist.expDate = "1893456000"
        playlist.maxConnections = "1"
        playlist.activeConnections = "0"
        playlist.lastSyncDate = Date().addingTimeInterval(-86400)
        playlist.serverVersion = "1.0.0"
        playlist.serverTimezone = "Europe/London"
        return playlist
    }

    static var sampleMovie: Movie {
        Movie(
            id: "\(samplePlaylistID)-movie-1",
            streamId: 1,
            name: "The Matrix",
            streamIcon: nil,
            rating: 8.7,
            rating5Based: 4.4,
            added: "2024-01-15",
            containerExtension: "mp4",
            num: 1,
            isAdult: 0,
            categoryId: nil
        )
    }

    static var sampleSeries: Series {
        Series(
            id: "\(samplePlaylistID)-series-1",
            seriesId: 1,
            name: "Breaking Bad",
            cover: nil,
            plot: "A high school chemistry teacher turned methamphetamine manufacturer partners with a former student.",
            cast: "Bryan Cranston, Aaron Paul, Anna Gunn",
            director: "Vince Gilligan",
            genre: "Crime, Drama, Thriller",
            releaseDate: "2008-01-20",
            rating: "9.5",
            rating5Based: "4.8",
            num: 1,
            categoryId: nil
        )
    }

    static var sampleLiveStream: LiveStream {
        LiveStream(
            id: "\(samplePlaylistID)-live-1",
            streamId: 100,
            name: "BBC One",
            streamIcon: nil,
            epgChannelId: "BBC1",
            tvArchive: 0,
            tvArchiveDuration: 0,
            num: 1,
            categoryId: nil
        )
    }
}

func previewContainer() -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    guard let container = try? ModelContainer(
        for: Playlist.self, Movie.self, Series.self, LiveStream.self,
        Category.self, Episode.self, CastMember.self,
        configurations: config
    ) else { fatalError("Failed to create ModelContainer") }

    let playlist = PreviewData.samplePlaylist
    container.mainContext.insert(playlist)

    let categories = [
        Category(apiId: "10", name: "Action", parentId: 0, type: .vod, playlist: playlist),
        Category(apiId: "11", name: "Comedy", parentId: 0, type: .vod, playlist: playlist),
        Category(apiId: "20", name: "News", parentId: 0, type: .live, playlist: playlist),
        Category(apiId: "30", name: "Drama", parentId: 0, type: .series, playlist: playlist)
    ]
    for cat in categories {
        container.mainContext.insert(cat)
    }

    insertMovies(into: container, categories: categories)
    insertSeries(into: container, categories: categories)
    insertLiveStreams(into: container, categories: categories)

    try? container.mainContext.save()
    return container
}

private func insertMovies(into container: ModelContainer, categories: [Category]) {
    insertBasicMovie(into: container, categories: categories)
    insertTMDBMovie(into: container, categories: categories)
    insertWatchedMovie(into: container, categories: categories)
}

private func insertBasicMovie(into container: ModelContainer, categories: [Category]) {
    let movie = PreviewData.sampleMovie
    movie.plot = "A computer hacker learns about the true nature of reality and his role in the war against its controllers."
    movie.genre = "Action, Sci-Fi"
    movie.releaseDate = "1999-03-31"
    movie.durationSecs = 8160
    movie.director = "Lana Wachowski, Lilly Wachowski"
    movie.actors = "Keanu Reeves, Laurence Fishburne, Carrie-Anne Moss"
    movie.youtubeTrailer = "d6j_wN1QO7s"
    movie.categoryId = categories[0].id
    container.mainContext.insert(movie)
}

private func insertTMDBMovie(into container: ModelContainer, categories: [Category]) {
    let movieTMDB = PreviewData.sampleMovie
    movieTMDB.id = "\(PreviewData.samplePlaylistID)-movie-tmdb"
    movieTMDB.name = "The Matrix"
    movieTMDB.streamId = 1
    movieTMDB.plot = "A computer hacker learns about the true nature of reality and his role in the war against its controllers."
    movieTMDB.genre = "Action, Sci-Fi"
    movieTMDB.releaseDate = "1999-03-31"
    movieTMDB.durationSecs = 8160
    movieTMDB.director = "Lana Wachowski, Lilly Wachowski"
    movieTMDB.actors = "Keanu Reeves, Laurence Fishburne, Carrie-Anne Moss"
    movieTMDB.youtubeTrailer = "d6j_wN1QO7s"
    movieTMDB.backdropPath = "/fNG7i7RqM1T0sP1vQmRIqRnW.jpg"
    movieTMDB.tagline = "Welcome to the Real World."
    movieTMDB.contentRating = "R"
    movieTMDB.tmdbId = 603
    movieTMDB.tmdb = "603"
    movieTMDB.tmdbEnrichedAt = Date().addingTimeInterval(-3600)
    movieTMDB.similarTMDBIds = [604, 605, 606, 607]
    movieTMDB.isFavorite = true
    movieTMDB.categoryId = categories[0].id

    let movieCast = [
        CastMember(id: "\(movieTMDB.id)-cast-0", tmdbPersonId: 6384, name: "Keanu Reeves", role: "Neo", profilePath: nil, order: 0, movie: movieTMDB),
        CastMember(id: "\(movieTMDB.id)-cast-1", tmdbPersonId: 6193, name: "Laurence Fishburne", role: "Morpheus", profilePath: nil, order: 1, movie: movieTMDB),
        CastMember(id: "\(movieTMDB.id)-cast-2", tmdbPersonId: 530, name: "Carrie-Anne Moss", role: "Trinity", profilePath: nil, order: 2, movie: movieTMDB),
        CastMember(id: "\(movieTMDB.id)-cast-3", tmdbPersonId: 192, name: "Hugo Weaving", role: "Agent Smith", profilePath: nil, order: 3, movie: movieTMDB)
    ]
    movieTMDB.castMembers = movieCast
    for cast in movieCast {
        container.mainContext.insert(cast)
    }
    container.mainContext.insert(movieTMDB)
}

private func insertWatchedMovie(into container: ModelContainer, categories: [Category]) {
    let movieWatched = PreviewData.sampleMovie
    movieWatched.id = "\(PreviewData.samplePlaylistID)-movie-2"
    movieWatched.name = "Inception"
    movieWatched.streamId = 2
    movieWatched.rating = 8.8
    movieWatched.tagline = "Your mind is the scene of the crime."
    movieWatched.plot = "A thief who steals corporate secrets through dream-sharing technology is given the task of planting an idea."
    movieWatched.genre = "Action, Sci-Fi, Thriller"
    movieWatched.releaseDate = "2010-07-16"
    movieWatched.durationSecs = 8880
    movieWatched.director = "Christopher Nolan"
    movieWatched.actors = "Leonardo DiCaprio, Joseph Gordon-Levitt, Elliot Page"
    movieWatched.youtubeTrailer = "YoHD9XEInc0"
    movieWatched.isWatched = true
    movieWatched.watchProgress = 8880
    movieWatched.isFavorite = false
    movieWatched.categoryId = categories[0].id
    container.mainContext.insert(movieWatched)
}

private func insertSeries(into container: ModelContainer, categories: [Category]) {
    let series = PreviewData.sampleSeries
    series.categoryId = categories[3].id
    container.mainContext.insert(series)

    let seriesTMDB = PreviewData.sampleSeries
    seriesTMDB.id = "\(PreviewData.samplePlaylistID)-series-tmdb"
    seriesTMDB.name = "Breaking Bad"
    seriesTMDB.seriesId = 1
    seriesTMDB.backdropPath = "/abc123backdrop.jpg"
    seriesTMDB.tagline = "I am the one who knocks."
    seriesTMDB.contentRating = "TV-MA"
    seriesTMDB.tmdbId = 1396
    seriesTMDB.tmdb = "1396"
    seriesTMDB.tmdbEnrichedAt = Date().addingTimeInterval(-3600)
    seriesTMDB.similarTMDBIds = [1397, 1398, 1399]
    seriesTMDB.isFavorite = true
    seriesTMDB.categoryId = categories[3].id

    let seriesCast = [
        CastMember(id: "\(seriesTMDB.id)-cast-0", tmdbPersonId: 17419, name: "Bryan Cranston", role: "Walter White", profilePath: nil, order: 0, series: seriesTMDB),
        CastMember(id: "\(seriesTMDB.id)-cast-1", tmdbPersonId: 234_989, name: "Aaron Paul", role: "Jesse Pinkman", profilePath: nil, order: 1, series: seriesTMDB),
        CastMember(id: "\(seriesTMDB.id)-cast-2", tmdbPersonId: 1_215_295, name: "Anna Gunn", role: "Skyler White", profilePath: nil, order: 2, series: seriesTMDB)
    ]
    seriesTMDB.castMembers = seriesCast
    for cast in seriesCast {
        container.mainContext.insert(cast)
    }

    let episodes = [
        Episode(id: "\(seriesTMDB.id)-ep-1", episodeId: "1", title: "Pilot", containerExtension: "mp4", seasonNum: 1, episodeNum: 1, series: seriesTMDB),
        Episode(id: "\(seriesTMDB.id)-ep-2", episodeId: "2", title: "Cat's in the Bag...", containerExtension: "mp4", seasonNum: 1, episodeNum: 2, series: seriesTMDB),
        Episode(id: "\(seriesTMDB.id)-ep-3", episodeId: "3", title: "And the Bag's in the River", containerExtension: "mp4", seasonNum: 1, episodeNum: 3, series: seriesTMDB),
        Episode(id: "\(seriesTMDB.id)-ep-4", episodeId: "4", title: "Cancer Man", containerExtension: "mp4", seasonNum: 1, episodeNum: 4, series: seriesTMDB)
    ]
    seriesTMDB.episodes = episodes
    for episode in episodes {
        container.mainContext.insert(episode)
    }
    container.mainContext.insert(seriesTMDB)

    let seriesNoEp = PreviewData.sampleSeries
    seriesNoEp.id = "\(PreviewData.samplePlaylistID)-series-2"
    seriesNoEp.name = "Stranger Things"
    seriesNoEp.seriesId = 2
    seriesNoEp.episodes = []
    seriesNoEp.isFavorite = false
    seriesNoEp.categoryId = categories[3].id
    container.mainContext.insert(seriesNoEp)
}

private func insertLiveStreams(into container: ModelContainer, categories: [Category]) {
    let live = PreviewData.sampleLiveStream
    live.categoryId = categories[2].id
    container.mainContext.insert(live)

    let liveArchive = PreviewData.sampleLiveStream
    liveArchive.id = "\(PreviewData.samplePlaylistID)-live-2"
    liveArchive.streamId = 101
    liveArchive.name = "CNN International"
    liveArchive.tvArchive = 1
    liveArchive.tvArchiveDuration = 7
    liveArchive.isFavorite = true
    liveArchive.categoryId = categories[2].id
    container.mainContext.insert(liveArchive)
}

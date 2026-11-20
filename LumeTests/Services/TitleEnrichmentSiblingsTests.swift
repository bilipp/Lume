//
//  TitleEnrichmentSiblingsTests.swift
//  LumeTests
//
//  TMDB details and MDBList ratings are per title: a row whose sibling (same
//  TMDB id) is freshly enriched copies it without a request, and a fetched
//  result reaches every sibling — cast only where the context allows it.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct TitleEnrichmentSiblingsTests {
    private let tmdbId = 603

    private func details(logo: String = "/logo.png") -> TMDBTitleDetails {
        TMDBTitleDetails(
            backdropPath: "/backdrop.jpg",
            overview: "A hacker learns the truth.",
            genreNames: ["Action", "Sci-Fi"],
            cast: [
                TMDBCastMember(tmdbPersonId: 1, name: "Keanu Reeves", character: "Neo", profilePath: nil, order: 0),
                TMDBCastMember(tmdbPersonId: 2, name: "Carrie-Anne Moss", character: "Trinity", profilePath: nil, order: 1)
            ],
            similarIDs: [604],
            videos: [],
            logoPath: logo
        )
    }

    private func movie(_ id: String, tmdbId: Int?, in context: ModelContext) -> Movie {
        let movie = Movie(id: id, streamId: 0, name: "The Matrix")
        movie.tmdbId = tmdbId
        context.insert(movie)
        return movie
    }

    private func series(_ id: String, tmdbId: Int?, in context: ModelContext) -> Series {
        let series = Series(id: id, seriesId: 0, name: "Dark")
        series.tmdbId = tmdbId
        context.insert(series)
        return series
    }

    private func ratingsData() throws -> Data {
        try JSONEncoder().encode([ExternalRating(source: .imdb, value: "8.7/10")])
    }

    // MARK: - TMDB skip-fetch

    @Test func `detail enrichment copies a freshly enriched movie sibling instead of fetching`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let source = movie("p1-movie-1", tmdbId: tmdbId, in: context)
        applyMovieDetails(details(logo: "/sibling.png"), to: source, context: context)
        let target = movie("p2-movie-1", tmdbId: tmdbId, in: context)
        try context.save()

        #expect(await enrichMovieDetails(target, tmdbId: tmdbId, context: context))

        #expect(target.logoPath == "/sibling.png")
        #expect(target.genre == "Action, Sci-Fi")
        #expect(target.similarTitleIds == [604])
        #expect(target.orderedCast.map(\.name) == ["Keanu Reeves", "Carrie-Anne Moss"])
        #expect(target.tmdbEnrichedAt != nil)
    }

    @Test func `a row that adopted a tmdb group enriches from the group's sibling, its own id left nil`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let source = movie("p1-movie-1", tmdbId: tmdbId, in: context)
        applyMovieDetails(details(logo: "/sibling.png"), to: source, context: context)
        let adopter = movie("p2-movie-1", tmdbId: nil, in: context)
        adopter.titleGroupKey = "tmdb:\(tmdbId)"
        try context.save()

        #expect(adopter.titleTMDBId == tmdbId)
        #expect(TitleEnrichmentSiblings.freshTMDBSibling(of: adopter) === source)
        let groupId = try #require(adopter.titleTMDBId)
        #expect(await enrichMovieDetails(adopter, tmdbId: groupId, context: context))

        #expect(adopter.logoPath == "/sibling.png")
        #expect(adopter.plot == "A hacker learns the truth.")
        #expect(adopter.tmdbId == nil)
    }

    @Test func `a stale sibling is not copied`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let source = movie("p1-movie-1", tmdbId: tmdbId, in: context)
        applyMovieDetails(details(), to: source, context: context)
        source.tmdbEnrichedAt = Date().addingTimeInterval(-30 * 24 * 3600)
        let target = movie("p2-movie-1", tmdbId: tmdbId, in: context)
        try context.save()

        #expect(!copyDetailsFromSibling(target, tmdbId: tmdbId, context: context, includeCast: true))
        #expect(target.logoPath == nil)
    }

    @Test func `a sibling with another TMDB id is not copied`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let other = movie("p1-movie-1", tmdbId: 604, in: context)
        applyMovieDetails(details(), to: other, context: context)
        let target = movie("p2-movie-1", tmdbId: tmdbId, in: context)
        try context.save()

        #expect(!copyDetailsFromSibling(target, tmdbId: tmdbId, context: context, includeCast: true))
    }

    @Test func `detail enrichment copies a freshly enriched series sibling instead of fetching`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let source = series("p1-series-1", tmdbId: tmdbId, in: context)
        applySeriesDetails(details(logo: "/sibling.png"), to: source, context: context)
        let target = series("p2-series-1", tmdbId: tmdbId, in: context)
        try context.save()

        #expect(await enrichSeriesDetails(target, tmdbId: tmdbId, context: context))

        #expect(target.logoPath == "/sibling.png")
        #expect(target.cast == "Keanu Reeves, Carrie-Anne Moss")
        #expect(target.orderedCast.count == 2)
        #expect(target.tmdbEnrichedAt != nil)
    }

    // MARK: - Background enrichment

    private func manager(_ container: ModelContainer) -> ContentSyncManager {
        let client = TMDBClient(session: TMDBRequestCounter.makeSession(), token: "test-token", language: "en-US")
        return ContentSyncManager(modelContainer: container, tmdbClient: client)
    }

    @Test func `background movie enrichment copies an enriched sibling without a TMDB request`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let source = movie("p1-movie-7001", tmdbId: 7001, in: context)
        applyMovieDetails(details(logo: "/sibling.png"), to: source, context: context)
        _ = movie("p2-movie-7001", tmdbId: 7001, in: context)
        try context.save()

        await manager(container).enrichMovie(id: "p2-movie-7001", tmdbId: 7001)

        #expect(TMDBRequestCounter.count(pathPrefix: "/3/movie/7001") == 0)
        let target = try #require(Movie.row(id: "p2-movie-7001", in: ModelContext(container)))
        #expect(target.logoPath == "/sibling.png")
        #expect(target.genre == "Action, Sci-Fi")
        #expect(target.castMembers.isEmpty)
        #expect(target.tmdbEnrichedAt == nil)
        #expect(TitleEnrichmentSiblings.siblingCast(of: target, in: ModelContext(container)).map(\.name)
            == ["Keanu Reeves", "Carrie-Anne Moss"])
    }

    @Test func `background series enrichment copies an enriched sibling without a TMDB request`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let source = series("p1-series-7002", tmdbId: 7002, in: context)
        applySeriesDetails(details(logo: "/sibling.png"), to: source, context: context)
        _ = series("p2-series-7002", tmdbId: 7002, in: context)
        try context.save()

        await manager(container).enrichSeries(id: "p2-series-7002", tmdbId: 7002)

        #expect(TMDBRequestCounter.count(pathPrefix: "/3/tv/7002") == 0)
        let target = try #require(Series.row(id: "p2-series-7002", in: ModelContext(container)))
        #expect(target.logoPath == "/sibling.png")
        #expect(target.cast == "Keanu Reeves, Carrie-Anne Moss")
        #expect(target.castMembers.isEmpty)
        #expect(target.tmdbEnrichedAt == nil)
    }

    @Test func `background enrichment without an enriched sibling requests TMDB`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        _ = movie("p1-movie-7003", tmdbId: 7003, in: context)
        _ = movie("p2-movie-7003", tmdbId: 7003, in: context)
        try context.save()

        await manager(container).enrichMovie(id: "p2-movie-7003", tmdbId: 7003)

        #expect(TMDBRequestCounter.count(pathPrefix: "/3/movie/7003") == 1)
    }

    @Test func `a second background movie enrichment of a copied row neither copies nor saves`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let source = movie("p1-movie-7004", tmdbId: 7004, in: context)
        applyMovieDetails(details(logo: "/sibling.png"), to: source, context: context)
        _ = movie("p2-movie-7004", tmdbId: 7004, in: context)
        try context.save()
        let manager = manager(container)
        await manager.enrichMovie(id: "p2-movie-7004", tmdbId: 7004)

        let saves = SaveCounter(container: container)
        await manager.enrichMovie(id: "p2-movie-7004", tmdbId: 7004)

        #expect(saves.count == 0)
        #expect(TMDBRequestCounter.count(pathPrefix: "/3/movie/7004") == 0)
        let target = try #require(Movie.row(id: "p2-movie-7004", in: ModelContext(container)))
        #expect(target.tmdbEnrichedAt == nil)
    }

    @Test func `a second background series enrichment of a copied row neither copies nor saves`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let source = series("p1-series-7005", tmdbId: 7005, in: context)
        applySeriesDetails(details(logo: "/sibling.png"), to: source, context: context)
        _ = series("p2-series-7005", tmdbId: 7005, in: context)
        try context.save()
        let manager = manager(container)
        await manager.enrichSeries(id: "p2-series-7005", tmdbId: 7005)

        let saves = SaveCounter(container: container)
        await manager.enrichSeries(id: "p2-series-7005", tmdbId: 7005)

        #expect(saves.count == 0)
        #expect(TMDBRequestCounter.count(pathPrefix: "/3/tv/7005") == 0)
        let target = try #require(Series.row(id: "p2-series-7005", in: ModelContext(container)))
        #expect(target.tmdbEnrichedAt == nil)
    }

    // MARK: - TMDB freshness

    @Test func `a stamped movie is fresh for the freshness window only`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let row = movie("p1-movie-1", tmdbId: tmdbId, in: context)
        applyMovieDetails(details(), to: row, context: context)
        try context.save()
        let stamp = try #require(row.tmdbEnrichedAt)

        #expect(row.hasFreshTMDBDetails(now: stamp.addingTimeInterval(3600)))
        #expect(!row.hasFreshTMDBDetails(now: stamp.addingTimeInterval(TitleEnrichmentSiblings.freshness + 1)))
    }

    @Test func `an unstamped movie is fresh once it holds a fresh sibling's details`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let source = movie("p1-movie-1", tmdbId: tmdbId, in: context)
        applyMovieDetails(details(), to: source, context: context)
        let target = movie("p2-movie-1", tmdbId: tmdbId, in: context)
        try context.save()
        let stamp = try #require(source.tmdbEnrichedAt)

        #expect(!target.hasFreshTMDBDetails())
        #expect(copyDetailsFromSibling(target, tmdbId: tmdbId, context: context, includeCast: false))
        #expect(target.tmdbEnrichedAt == nil)
        #expect(target.hasFreshTMDBDetails())
        #expect(!target.hasFreshTMDBDetails(now: stamp.addingTimeInterval(TitleEnrichmentSiblings.freshness + 1)))

        applyMovieDetails(details(logo: "/new.png"), to: source, context: context)
        #expect(!target.hasFreshTMDBDetails())
    }

    @Test func `one copy makes a movie fresh when the fill-if-blank fields can't change`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let source = movie("p1-movie-1", tmdbId: tmdbId, in: context)
        var sourceDetails = details()
        sourceDetails.releaseDate = "N/A"
        sourceDetails.runtimeMinutes = 136
        sourceDetails.voteAverage = 8.7
        applyMovieDetails(sourceDetails, to: source, context: context)
        let target = movie("p2-movie-1", tmdbId: tmdbId, in: context)
        target.durationSecs = 45
        try context.save()

        #expect(copyDetailsFromSibling(target, tmdbId: tmdbId, context: context, includeCast: false))
        #expect(target.releaseDate == "N/A")
        #expect(target.durationSecs == 45)
        #expect(target.rating == 8.7)
        #expect(target.hasFreshTMDBDetails())
    }

    @Test func `an unstamped series is fresh once it holds a fresh sibling's details`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let source = series("p1-series-1", tmdbId: tmdbId, in: context)
        applySeriesDetails(details(), to: source, context: context)
        let target = series("p2-series-1", tmdbId: tmdbId, in: context)
        let unrelated = series("p3-series-1", tmdbId: 604, in: context)
        try context.save()

        #expect(!target.hasFreshTMDBDetails())
        #expect(copyDetailsFromSibling(target, tmdbId: tmdbId, context: context, includeCast: false))
        #expect(target.hasFreshTMDBDetails())
        #expect(!unrelated.hasFreshTMDBDetails())
    }

    // MARK: - TMDB fan-out

    @Test func `fetched movie details reach every sibling, cast only on the requested row in the background`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let target = movie("p1-movie-1", tmdbId: tmdbId, in: context)
        let sibling = movie("p2-movie-1", tmdbId: tmdbId, in: context)
        let unrelated = movie("p3-movie-1", tmdbId: 604, in: context)
        try context.save()

        applyDetailsToSiblings(
            details(), to: target, tmdbId: tmdbId, context: context, siblingsIncludeCast: false
        )

        #expect(target.castMembers.count == 2)
        #expect(target.tmdbEnrichedAt != nil)
        #expect(sibling.logoPath == "/logo.png")
        #expect(sibling.genre == "Action, Sci-Fi")
        #expect(sibling.castMembers.isEmpty)
        #expect(sibling.tmdbEnrichedAt == nil)
        #expect(unrelated.logoPath == nil)
    }

    @Test func `fetched series details on the view context stamp every sibling with cast`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let target = series("p1-series-1", tmdbId: tmdbId, in: context)
        let sibling = series("p2-series-1", tmdbId: tmdbId, in: context)
        try context.save()

        applyDetailsToSiblings(
            details(), to: target, tmdbId: tmdbId, context: context, siblingsIncludeCast: true
        )

        #expect(target.castMembers.count == 2)
        #expect(sibling.castMembers.count == 2)
        #expect(Set(sibling.castMembers.map(\.id)).isDisjoint(with: target.castMembers.map(\.id)))
        #expect(sibling.tmdbEnrichedAt != nil)
        #expect(sibling.logoPath == "/logo.png")
    }

    // MARK: - MDBList ratings

    @Test func `enrichMovieRatings copies a sibling's fresh ratings instead of fetching`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let enrichedAt = Date().addingTimeInterval(-3600)
        let source = movie("p1-movie-1", tmdbId: tmdbId, in: context)
        source.externalRatingsData = try ratingsData()
        source.ratingsEnrichedAt = enrichedAt
        _ = movie("p2-movie-1", tmdbId: tmdbId, in: context)
        try context.save()

        await ContentSyncManager(modelContainer: container).enrichMovieRatings(movieId: "p2-movie-1", tmdbId: tmdbId)

        let reader = ModelContext(container)
        let target = try #require(Movie.row(id: "p2-movie-1", in: reader))
        #expect(target.externalRatings == [ExternalRating(source: .imdb, value: "8.7/10")])
        #expect(target.ratingsEnrichedAt == enrichedAt)
    }

    @Test func `enrichSeriesRatings copies a sibling's fresh ratings instead of fetching`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let source = series("p1-series-1", tmdbId: tmdbId, in: context)
        source.externalRatingsData = try ratingsData()
        source.ratingsEnrichedAt = Date()
        _ = series("p2-series-1", tmdbId: tmdbId, in: context)
        try context.save()

        await ContentSyncManager(modelContainer: container).enrichSeriesRatings(seriesId: "p2-series-1", tmdbId: tmdbId)

        let reader = ModelContext(container)
        let target = try #require(Series.row(id: "p2-series-1", in: reader))
        #expect(target.externalRatings.map(\.value) == ["8.7/10"])
    }

    @Test func `stale sibling ratings are not copied`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let source = movie("p1-movie-1", tmdbId: tmdbId, in: context)
        source.externalRatingsData = try ratingsData()
        source.ratingsEnrichedAt = Date().addingTimeInterval(-30 * 24 * 3600)
        let target = movie("p2-movie-1", tmdbId: tmdbId, in: context)

        #expect(!TitleEnrichmentSiblings.copyRatings(from: [source], to: target))
        #expect(target.externalRatingsData == nil)
    }

    @Test func `fetched ratings reach every sibling`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let target = movie("p1-movie-1", tmdbId: tmdbId, in: context)
        let sibling = movie("p2-movie-1", tmdbId: tmdbId, in: context)
        try context.save()
        let now = Date()

        TitleEnrichmentSiblings.applyRatings(
            [ExternalRating(source: .imdb, value: "8.7/10")],
            to: target,
            siblings: Movie.rows(sharing: tmdbId, except: target.id, in: context),
            now: now
        )

        #expect(target.ratingsEnrichedAt == now)
        #expect(sibling.ratingsEnrichedAt == now)
        #expect(sibling.externalRatings.map(\.value) == ["8.7/10"])
    }
}

/// Counts the saves of every context on one container.
private final nonisolated class SaveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var saves = 0
    private var observer: NSObjectProtocol?

    var count: Int {
        lock.withLock { saves }
    }

    init(container: ModelContainer) {
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, (note.object as? ModelContext)?.container === container else { return }
            increment()
        }
    }

    private func increment() {
        lock.withLock { saves += 1 }
    }

    deinit {
        observer.map(NotificationCenter.default.removeObserver)
    }
}

/// Counts TMDB requests by path and answers each with an empty object. Each
/// test uses its own TMDB id, so parallel tests never share a path.
private final nonisolated class TMDBRequestCounter: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var paths: [String] = []

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TMDBRequestCounter.self]
        return URLSession(configuration: config)
    }

    static func count(pathPrefix: String) -> Int {
        lock.withLock { paths.count { $0.hasPrefix(pathPrefix) } }
    }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.withLock { Self.paths.append(url.path) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

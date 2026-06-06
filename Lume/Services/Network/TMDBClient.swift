//
//  TMDBClient.swift
//  Lume
//
//  Lightweight read-only client for The Movie Database (TMDB).
//  Used to power the "Trending" section on the home screen.
//
//  The v4 read access token lives in the git-ignored `.env` file and is
//  injected into Info.plist at build time by Scripts/inject-env.sh — it is
//  never committed to source control.
//

import Foundation

enum TMDBError: Error {
    case missingToken
    case invalidURL
    case invalidResponse
    case serverError(Int)
    case decodingError(Error)
}

/// Read-only TMDB API client. Only the endpoints the home screen needs are implemented (trending)
nonisolated struct TMDBClient {
    static let shared = TMDBClient()

    enum MediaType: String {
        case movie
        case tvShow = "tv"
    }

    enum TimeWindow: String {
        case day
        case week
    }

    private let baseURL = "https://api.themoviedb.org/3"
    private static let imageBaseURL = "https://image.tmdb.org/t/p/"
    private let session: URLSession
    private let token: String?

    init(session: URLSession = .shared, token: String? = TMDBClient.tokenFromBundle()) {
        self.session = session
        self.token = token
    }

    /// Whether a usable token is present. When false the trending section is
    /// simply hidden rather than surfacing an error to the user.
    var isConfigured: Bool {
        guard let token, !token.isEmpty else { return false }
        // Guard against an unsubstituted Info.plist variable (no xcconfig present).
        return !token.hasPrefix("$(")
    }

    static func tokenFromBundle() -> String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "TMDBAccessToken") as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns trending titles enriched with the artwork and copy the home hero
    /// carousel needs (backdrop, title, overview), in popularity order.
    ///
    /// Fetches up to `pages` pages (20 titles each) so the home screen has a
    /// larger pool to match against the active playlist — the trending row only
    /// shows titles already in the library, so a wider net surfaces more of them.
    func trending(_ media: MediaType, timeWindow: TimeWindow = .week, pages: Int = 5) async throws -> [TrendingTitle] {
        let basePath = "/trending/\(media.rawValue)/\(timeWindow.rawValue)"

        // Fetch the first page up front so we learn the real page count and
        // never request pages beyond what TMDB has.
        let first: TrendingResponse = try await get("\(basePath)?page=1")
        let pageCount = min(max(pages, 1), max(first.totalPages ?? 1, 1))

        var itemsByPage: [Int: [TrendingItem]] = [1: first.results]
        if pageCount > 1 {
            try await withThrowingTaskGroup(of: (Int, [TrendingItem]).self) { group in
                for page in 2 ... pageCount {
                    group.addTask {
                        let response: TrendingResponse = try await get("\(basePath)?page=\(page)")
                        return (page, response.results)
                    }
                }
                for try await (page, results) in group {
                    itemsByPage[page] = results
                }
            }
        }

        // Reassemble in page order to preserve TMDB's popularity ranking.
        return (1 ... pageCount)
            .flatMap { itemsByPage[$0] ?? [] }
            .map {
                TrendingTitle(
                    id: $0.id,
                    title: $0.title ?? $0.name ?? "",
                    overview: $0.overview ?? "",
                    backdropPath: $0.backdropPath
                )
            }
    }

    static var heroBackdropSize: String {
        "w1920"
    }

    static var heroLogoSize: String {
        #if os(tvOS)
            "original"
        #else
            "w500"
        #endif
    }

    /// Builds a full image URL from a TMDB relative path (e.g. `/abc.jpg`).
    /// Defaults to the platform-appropriate hero backdrop size.
    static func backdropURL(_ path: String?, size: String = heroBackdropSize) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBaseURL + size + path)
    }

    /// Builds a full cast-profile image URL from a TMDB relative path.
    static func profileURL(_ path: String?, size: String = "w185") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBaseURL + size + path)
    }

    /// Builds a full title-logo image URL from a TMDB relative path. Logos are
    /// transparent PNGs of the title's wordmark, sized for the hero treatments.
    static func logoURL(_ path: String?, size: String = heroLogoSize) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBaseURL + size + path)
    }

    // MARK: - Title details

    /// Full detail payload for a movie, with credits, similar titles and the
    /// US content rating folded in via `append_to_response`.
    func movieDetails(_ id: Int) async throws -> TMDBTitleDetails {
        let response: TitleDetailsResponse = try await get(
            "/movie/\(id)?append_to_response=credits,similar,release_dates,images,videos"
        )
        return response.normalized(isMovie: true)
    }

    /// Full detail payload for a TV series.
    func tvDetails(_ id: Int) async throws -> TMDBTitleDetails {
        let response: TitleDetailsResponse = try await get(
            "/tv/\(id)?append_to_response=credits,similar,content_ratings,images,videos"
        )
        return response.normalized(isMovie: false)
    }

    /// Returns the list of TMDB movie IDs that belong to a collection.
    func collectionMovieIDs(_ id: Int) async throws -> [Int] {
        let response: CollectionDetailsResponse = try await get("/collection/\(id)")
        return response.parts.map(\.id)
    }

    // MARK: - Networking

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard isConfigured, let token else { throw TMDBError.missingToken }
        guard let url = URL(string: baseURL + path) else { throw TMDBError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TMDBError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw TMDBError.serverError(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TMDBError.decodingError(error)
        }
    }
}

// MARK: - Public types

/// A trending title with the metadata the home hero carousel renders.
struct TrendingTitle: Identifiable, Hashable {
    let id: Int
    let title: String
    let overview: String
    let backdropPath: String?
}

/// Normalized TMDB detail payload shared by movies and series. Empty/absent
/// fields are represented as nil / empty arrays so callers can fill gaps in
/// provider metadata without special-casing the media type.
struct TMDBTitleDetails {
    var backdropPath: String?
    var tagline: String?
    var overview: String?
    var voteAverage: Double?
    var runtimeMinutes: Int?
    var genreNames: [String]
    var contentRating: String?
    var cast: [TMDBCastMember]
    var similarIDs: [Int]
    /// YouTube videos (trailers, teasers, clips) in display order.
    var videos: [TitleVideo]
    /// Relative path to the title's wordmark logo (transparent PNG), if any.
    var logoPath: String?

    /// Collection this movie belongs to (only for movies, nil for series).
    var collectionId: Int?
    var collectionName: String?
    var collectionPosterPath: String?
    var collectionBackdropPath: String?
}

/// One billed performer from TMDB credits.
struct TMDBCastMember: Hashable {
    let tmdbPersonId: Int
    let name: String
    let character: String?
    let profilePath: String?
    let order: Int
}

// MARK: - DTOs

private nonisolated struct TrendingResponse: Decodable {
    let results: [TrendingItem]
    let totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case results
        case totalPages = "total_pages"
    }
}

private nonisolated struct TrendingItem: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let backdropPath: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case backdropPath = "backdrop_path"
    }
}

/// Decodes `/movie/{id}` and `/tv/{id}` responses (with `credits`, `similar`
/// and certifications appended). Every field is optional so a single shape
/// works for both endpoints.
private nonisolated struct TitleDetailsResponse: Decodable {
    let backdropPath: String?
    let tagline: String?
    let overview: String?
    let voteAverage: Double?
    let runtime: Int? // movies
    let episodeRunTime: [Int]? // tv
    let genres: [Genre]?
    let credits: Credits?
    let similar: Similar?
    let releaseDates: Results<ReleaseDatesEntry>? // movies
    let contentRatings: Results<ContentRatingEntry>? // tv
    let belongsToCollection: BelongsToCollection?
    let videos: Results<VideoEntry>?
    let images: ImagesEntry?

    struct Genre: Decodable { let name: String }
    struct Credits: Decodable { let cast: [TMDBCastMemberDTO]? }
    struct Similar: Decodable { let results: [SimilarItem] }
    struct Results<Entry: Decodable>: Decodable { let results: [Entry] }
    enum CodingKeys: String, CodingKey {
        case tagline, overview, runtime, genres, credits, similar, videos, images
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case episodeRunTime = "episode_run_time"
        case releaseDates = "release_dates"
        case contentRatings = "content_ratings"
        case belongsToCollection = "belongs_to_collection"
    }
}

private nonisolated struct BelongsToCollection: Decodable {
    let id: Int
    let name: String?
    let posterPath: String?
    let backdropPath: String?
    enum CodingKeys: String, CodingKey {
        case id, name
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }
}

private nonisolated struct ReleaseDatesEntry: Decodable {
    let countryCode: String
    let releaseDates: [ReleaseDateEntry]
    enum CodingKeys: String, CodingKey {
        case countryCode = "iso_3166_1"
        case releaseDates = "release_dates"
    }
}

private nonisolated struct ContentRatingEntry: Decodable {
    let countryCode: String
    let rating: String?
    enum CodingKeys: String, CodingKey {
        case countryCode = "iso_3166_1"
        case rating
    }
}

private nonisolated struct TMDBCastMemberDTO: Decodable {
    let id: Int
    let name: String
    let character: String?
    let profilePath: String?
    let order: Int?
    enum CodingKeys: String, CodingKey {
        case id, name, character, order
        case profilePath = "profile_path"
    }
}

private nonisolated struct SimilarItem: Decodable { let id: Int }

private nonisolated struct VideoEntry: Decodable {
    let key: String
    let name: String?
    let site: String?
    let type: String?
    let official: Bool?
}

private nonisolated struct ImagesEntry: Decodable {
    let logos: [LogoEntry]?
}

private nonisolated struct LogoEntry: Decodable {
    let filePath: String
    let languageCode: String?
    let voteAverage: Double?
    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case languageCode = "iso_639_1"
        case voteAverage = "vote_average"
    }
}

private nonisolated struct ReleaseDateEntry: Decodable { let certification: String? }

private nonisolated struct CollectionDetailsResponse: Decodable {
    let id: Int
    let parts: [CollectionPart]
}

private nonisolated struct CollectionPart: Decodable {
    let id: Int
}

nonisolated extension TitleDetailsResponse {
    func normalized(isMovie: Bool) -> TMDBTitleDetails {
        let cast = (credits?.cast ?? [])
            .sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            .prefix(20)
            .map {
                TMDBCastMember(
                    tmdbPersonId: $0.id,
                    name: $0.name,
                    character: $0.character?.isEmpty == true ? nil : $0.character,
                    profilePath: $0.profilePath,
                    order: $0.order ?? 0
                )
            }

        return TMDBTitleDetails(
            backdropPath: backdropPath,
            tagline: (tagline?.isEmpty == true) ? nil : tagline,
            overview: (overview?.isEmpty == true) ? nil : overview,
            voteAverage: voteAverage,
            runtimeMinutes: isMovie ? runtime : episodeRunTime?.first,
            genreNames: genres?.map(\.name) ?? [],
            contentRating: isMovie ? movieCertification() : tvRating(),
            cast: Array(cast),
            similarIDs: similar?.results.map(\.id) ?? [],
            videos: mappedVideos(),
            logoPath: bestLogoPath(),
            collectionId: isMovie ? belongsToCollection?.id : nil,
            collectionName: isMovie ? belongsToCollection?.name : nil,
            collectionPosterPath: isMovie ? belongsToCollection?.posterPath : nil,
            collectionBackdropPath: isMovie ? belongsToCollection?.backdropPath : nil
        )
    }

    /// YouTube videos sorted by usefulness — trailers first, then teasers,
    /// clips and featurettes — with official entries leading within each kind.
    private func mappedVideos() -> [TitleVideo] {
        let priority: [String: Int] = [
            "Trailer": 0, "Teaser": 1, "Clip": 2, "Featurette": 3, "Behind the Scenes": 4
        ]
        return (videos?.results ?? [])
            .filter { $0.site == "YouTube" && !$0.key.isEmpty }
            .sorted { lhs, rhs in
                let lhsKey = (priority[lhs.type ?? ""] ?? 99, (lhs.official ?? false) ? 0 : 1)
                let rhsKey = (priority[rhs.type ?? ""] ?? 99, (rhs.official ?? false) ? 0 : 1)
                return lhsKey < rhsKey
            }
            .prefix(12)
            .map { TitleVideo(key: $0.key, name: ($0.name?.isEmpty == false) ? $0.name! : "Video", type: $0.type ?? "Video") }
    }

    /// Picks the best wordmark logo: an English one first, then a
    /// language-neutral one, then any other; ties broken by TMDB vote average.
    private func bestLogoPath() -> String? {
        let logos = images?.logos ?? []
        guard !logos.isEmpty else { return nil }
        func rank(_ logo: LogoEntry) -> Int {
            switch logo.languageCode {
            case "en": 0
            case nil, "": 1
            default: 2
            }
        }
        return logos
            .sorted { (rank($0), -($0.voteAverage ?? 0)) < (rank($1), -($1.voteAverage ?? 0)) }
            .first?.filePath
    }

    /// Picks a US certification, falling back to the first non-empty one.
    private func movieCertification() -> String? {
        let entries = releaseDates?.results ?? []
        func cert(for code: String) -> String? {
            entries.first { $0.countryCode == code }?
                .releaseDates.compactMap(\.certification)
                .first { !$0.isEmpty }
        }
        if let usCert = cert(for: "US") { return usCert }
        for entry in entries {
            if let cert = entry.releaseDates.compactMap(\.certification).first(where: { !$0.isEmpty }) {
                return cert
            }
        }
        return nil
    }

    private func tvRating() -> String? {
        let entries = contentRatings?.results ?? []
        if let usRating = entries.first(where: { $0.countryCode == "US" })?.rating, !usRating.isEmpty { return usRating }
        return entries.compactMap(\.rating).first { !$0.isEmpty }
    }
}

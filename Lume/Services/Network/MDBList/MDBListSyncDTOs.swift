//
//  MDBListSyncDTOs.swift
//  Lume
//
//  The request and response shapes of `MDBListSyncClient`: OAuth device-flow
//  and token responses, the watched-history sync payloads, the paginated
//  watched-history and watchlist pages, and the date formats MDBList mixes.
//

import Foundation

// MARK: - OAuth DTOs

/// Decoded `/oauth/device-authorization/` response. MDBList's own client falls
/// back to the plain code page, a 5 s interval and a 5-minute lifetime when a
/// field is missing, so the same defaults apply here.
nonisolated struct MDBListDeviceCode: Decodable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let verificationURLComplete: String?
    let expiresIn: Int
    let interval: Int

    init(
        deviceCode: String,
        userCode: String,
        verificationURL: String,
        verificationURLComplete: String?,
        expiresIn: Int,
        interval: Int
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.verificationURLComplete = verificationURLComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceCode = try container.decode(String.self, forKey: .deviceCode)
        userCode = try container.decode(String.self, forKey: .userCode)
        verificationURL = try container.decodeIfPresent(String.self, forKey: .verificationURL)
            ?? "https://mdblist.com/oauth/device/"
        verificationURLComplete = try container.decodeIfPresent(String.self, forKey: .verificationURLComplete)
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 300
        interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 5
    }

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURL = "verification_uri"
        case verificationURLComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

/// Decoded `/oauth/token/` response, shared by the device and refresh grants.
nonisolated struct MDBListTokenResponse: Decodable {
    let accessToken: String
    /// Nil when a refresh answers without rotating the refresh token.
    let refreshToken: String?
    /// Access tokens live 30 days (`expires_in: 2592000`).
    let expiresIn: TimeInterval?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }

    /// The token set to store. `previousRefreshToken` stands in when the
    /// response carries none of its own.
    func tokens(previousRefreshToken: String? = nil) -> MDBListTokens {
        MDBListTokens(
            accessToken: accessToken,
            refreshToken: refreshToken ?? previousRefreshToken ?? "",
            issuedAt: Date().timeIntervalSince1970,
            expiresIn: expiresIn ?? 2_592_000,
            scope: scope
        )
    }
}

nonisolated struct MDBListUser: Decodable {
    let username: String?
    let name: String?

    /// What "Connected as …" shows.
    var displayName: String? {
        [username, name].compactMap(\.self).first { !$0.isEmpty }
    }
}

// MARK: - Sync payloads

/// External-id bag accepted by the sync endpoints. Only the TMDB id is known
/// for library titles, and MDBList resolves it on its end.
nonisolated struct MDBListIDs: Codable, Equatable {
    var tmdb: Int?

    init(tmdb: Int?) {
        self.tmdb = tmdb
    }

    /// MDBList mixes integers and strings in its id fields, so the TMDB id
    /// decodes either way.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let int = try? container.decode(Int.self, forKey: .tmdb) {
            tmdb = int
        } else if let string = try? container.decode(String.self, forKey: .tmdb) {
            tmdb = Int(string)
        } else {
            tmdb = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case tmdb
    }
}

nonisolated struct MDBListMoviePayload: Encodable {
    let title: String?
    let ids: MDBListIDs
}

nonisolated struct MDBListEpisodeNumber: Encodable {
    let number: Int
}

nonisolated struct MDBListSeasonPayload: Encodable {
    let number: Int
    let episodes: [MDBListEpisodeNumber]
}

nonisolated struct MDBListShowPayload: Encodable {
    let title: String?
    let ids: MDBListIDs
    let seasons: [MDBListSeasonPayload]
}

/// Body for `/sync/watched` and `/sync/watched/remove`. Only the populated
/// arrays are encoded. An episode is always sent nested under its season —
/// a show or season without episodes would cascade to every episode in it.
nonisolated struct MDBListSyncItems: Encodable {
    var movies: [MDBListMoviePayload] = []
    var shows: [MDBListShowPayload] = []

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !movies.isEmpty {
            try container.encode(movies, forKey: .movies)
        }
        if !shows.isEmpty {
            try container.encode(shows, forKey: .shows)
        }
    }

    enum CodingKeys: String, CodingKey {
        case movies, shows
    }

    static func movie(tmdbID: Int, title: String?) -> MDBListSyncItems {
        MDBListSyncItems(movies: [MDBListMoviePayload(title: title, ids: MDBListIDs(tmdb: tmdbID))])
    }

    static func episode(showTMDBID: Int, showTitle: String?, season: Int, episode: Int) -> MDBListSyncItems {
        MDBListSyncItems(shows: [
            MDBListShowPayload(
                title: showTitle,
                ids: MDBListIDs(tmdb: showTMDBID),
                seasons: [MDBListSeasonPayload(number: season, episodes: [MDBListEpisodeNumber(number: episode)])]
            )
        ])
    }
}

// MARK: - Pagination

/// The `pagination` block shared by the sync and watchlist responses.
nonisolated struct MDBListPagination: Decodable {
    let hasMore: Bool?
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }
}

nonisolated protocol MDBListPaged {
    var pagination: MDBListPagination? { get }
    /// Rows on this page; an empty page ends the walk.
    var itemCount: Int { get }
}

// MARK: - Watched history (import)

/// Decoded `/sync/watched` page. Arrays a page doesn't carry decode as empty.
nonisolated struct MDBListWatchedHistory: Decodable, MDBListPaged {
    var movies: [MDBListWatchedMovie]
    var episodes: [MDBListWatchedEpisode]
    var pagination: MDBListPagination?

    var itemCount: Int {
        movies.count + episodes.count
    }

    init(movies: [MDBListWatchedMovie], episodes: [MDBListWatchedEpisode]) {
        self.movies = movies
        self.episodes = episodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movies = try container.decodeIfPresent([MDBListWatchedMovie].self, forKey: .movies) ?? []
        episodes = try container.decodeIfPresent([MDBListWatchedEpisode].self, forKey: .episodes) ?? []
        pagination = try container.decodeIfPresent(MDBListPagination.self, forKey: .pagination)
    }

    enum CodingKeys: String, CodingKey {
        case movies, episodes, pagination
    }
}

/// One `movies` row. Unwatching keeps the row with a null timestamp, so only a
/// row that carries one counts as watched.
nonisolated struct MDBListWatchedMovie: Decodable {
    let lastWatchedAt: String?
    let movie: MDBListWatchedMedia

    enum CodingKeys: String, CodingKey {
        case lastWatchedAt = "last_watched_at"
        case movie
    }
}

/// One `episodes` row: the episode's numbers plus its show's ids.
nonisolated struct MDBListWatchedEpisode: Decodable {
    let lastWatchedAt: String?
    let episode: Row

    nonisolated struct Row: Decodable {
        let season: Int
        let number: Int
        let show: MDBListWatchedMedia
    }

    enum CodingKeys: String, CodingKey {
        case lastWatchedAt = "last_watched_at"
        case episode
    }
}

nonisolated struct MDBListWatchedMedia: Decodable {
    let ids: MDBListIDs
}

// MARK: - Watchlist

/// A watchlist title reduced to what Home matches on: movie or show, and its
/// TMDB id.
nonisolated struct MDBListWatchlistEntry: Equatable {
    enum Kind {
        case movie
        case show
    }

    let kind: Kind
    let tmdbID: Int
    let addedAt: Date?
}

/// Decoded `/watchlist/items` page.
nonisolated struct MDBListWatchlistPage: Decodable, MDBListPaged {
    let movies: [MDBListWatchlistItem]
    let shows: [MDBListWatchlistItem]
    let pagination: MDBListPagination?

    var itemCount: Int {
        movies.count + shows.count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movies = try container.decodeIfPresent([MDBListWatchlistItem].self, forKey: .movies) ?? []
        shows = try container.decodeIfPresent([MDBListWatchlistItem].self, forKey: .shows) ?? []
        pagination = try container.decodeIfPresent(MDBListPagination.self, forKey: .pagination)
    }

    enum CodingKeys: String, CodingKey {
        case movies, shows, pagination
    }

    var entries: [MDBListWatchlistEntry] {
        movies.compactMap { $0.entry(kind: .movie) } + shows.compactMap { $0.entry(kind: .show) }
    }
}

/// One watchlist row. Its `id` is the title's TMDB id; a newer `ids` block is
/// read first when present.
nonisolated struct MDBListWatchlistItem: Decodable {
    let id: Int?
    let ids: MDBListIDs?
    let watchlistAt: String?

    enum CodingKeys: String, CodingKey {
        case id, ids
        case watchlistAt = "watchlist_at"
    }

    fileprivate func entry(kind: MDBListWatchlistEntry.Kind) -> MDBListWatchlistEntry? {
        guard let tmdbID = ids?.tmdb ?? id else { return nil }
        return MDBListWatchlistEntry(kind: kind, tmdbID: tmdbID, addedAt: MDBListDates.parse(watchlistAt))
    }
}

// MARK: - Dates

nonisolated enum MDBListDates {
    /// The sync endpoints use ISO-8601 (`2025-10-21T12:00:00Z`); the watchlist
    /// uses a space-separated UTC timestamp with microseconds
    /// (`2025-02-02 17:28:22.000000`). Every form is tried.
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return iso.date(from: string)
            ?? isoFractional.date(from: string)
            ?? spaced.date(from: string)
            ?? spacedWhole.date(from: string)
    }

    private static let iso = ISO8601DateFormatter()

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let spaced = makeSpaced("yyyy-MM-dd HH:mm:ss.SSSSSS")
    private static let spacedWhole = makeSpaced("yyyy-MM-dd HH:mm:ss")

    private static func makeSpaced(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}

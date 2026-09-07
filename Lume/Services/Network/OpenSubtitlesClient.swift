//
//  OpenSubtitlesClient.swift
//  Lume
//
//  Stateless client for the OpenSubtitles REST API (https://opensubtitles.com),
//  used to find and fetch external subtitle tracks for the title currently
//  playing.
//
//  Two credentials are in play and they are not interchangeable:
//
//  * The **API key** identifies the Lume build. It lives in the git-ignored
//    `.env` file (OPENSUBTITLES_API_KEY) and is injected into Info.plist at
//    build time by Scripts/inject-env.sh — never committed. Without it the whole
//    integration hides itself.
//  * A **user token** identifies the viewer. `/subtitles` search works
//    anonymously, but `/download` answers 401 "missing token" without one, and
//    the daily download quota is per account — so downloading requires the user
//    to sign in with their own OpenSubtitles account (see `OpenSubtitlesService`).
//
//  Two API quirks worth knowing:
//
//  * `/subtitles` canonicalises its query string: unsorted parameters get a 301
//    to the sorted form. `searchURL(for:)` sorts them itself so no request is
//    ever paid for twice.
//  * A successful `/login` may return a different `base_url` (VIP accounts get
//    their own host). Callers persist it and hand it back in `host`.
//

import Foundation

// MARK: - Errors

enum OpenSubtitlesError: Error, Equatable {
    case notConfigured
    case invalidResponse
    /// The endpoint needs a user token and none was supplied (or it expired).
    case notAuthenticated
    case invalidCredentials
    /// The account's daily download allowance is spent.
    case quotaExceeded
    case server(Int)
    case decoding

    /// User-facing explanation, shown in the search sheet and the settings pane.
    var message: LocalizedStringResource {
        switch self {
        case .notConfigured:
            "Subtitle search isn't available in this build."
        case .invalidCredentials:
            // The email address is the common wrong guess, and the API's own
            // reply ("invalid username/password") doesn't say so — name it at
            // the moment the sign-in actually fails.
            "Wrong username or password. OpenSubtitles wants your username here, not your email address."
        case .notAuthenticated:
            "Sign in to your OpenSubtitles account to download subtitles."
        case .quotaExceeded:
            "You've used up today's OpenSubtitles downloads. Try again tomorrow."
        case .invalidResponse, .decoding:
            "OpenSubtitles sent an unexpected response."
        case let .server(code):
            "OpenSubtitles couldn't be reached (error \(code))."
        }
    }
}

// MARK: - Search query

/// The identifiers a search is keyed on. Prefer the ids: matching on `text`
/// alone drags in remakes and same-named titles, while a TMDB/IMDb id pins the
/// exact feature. Episodes search by their *series'* id plus season/episode —
/// that is what OpenSubtitles indexes them under.
nonisolated struct OpenSubtitlesQuery: Equatable {
    var text: String?
    var imdbId: String?
    var tmdbId: Int?
    var parentImdbId: String?
    var parentTmdbId: Int?
    var season: Int?
    var episode: Int?
    var languages: [String] = []

    /// Whether there is anything to search on. A query with only a language
    /// filter would return the whole catalogue.
    var isEmpty: Bool {
        let hasText = !(text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return !hasText && !hasIdentifier
    }

    var hasIdentifier: Bool {
        imdbId != nil || tmdbId != nil || parentImdbId != nil || parentTmdbId != nil
    }

    /// The one id this search is keyed on.
    ///
    /// Exactly one, never several: OpenSubtitles **ANDs** its parameters, so a
    /// record has to match every id sent. A catalog whose `imdbId` disagrees
    /// with its `tmdbId` — routine, since the two can come from different
    /// enrichment passes or straight from the provider — then matches nothing
    /// at all. Measured against *One Battle After Another*: `tmdb_id` alone
    /// returns 5 German subtitles, `imdb_id` alone 4, and the correct
    /// `tmdb_id` paired with a mismatched `imdb_id` returns 0.
    ///
    /// TMDB first because that is the id Lume's own enrichment writes and the
    /// one the catalog is keyed on elsewhere (`#Index([\.tmdbId])`).
    var identifier: URLQueryItem? {
        if let tmdbId {
            URLQueryItem(name: "tmdb_id", value: String(tmdbId))
        } else if let imdbId = OpenSubtitlesClient.normalizedIMDbId(imdbId) {
            URLQueryItem(name: "imdb_id", value: imdbId)
        } else if let parentTmdbId {
            URLQueryItem(name: "parent_tmdb_id", value: String(parentTmdbId))
        } else if let parentImdbId = OpenSubtitlesClient.normalizedIMDbId(parentImdbId) {
            URLQueryItem(name: "parent_imdb_id", value: parentImdbId)
        } else {
            nil
        }
    }

    /// A copy keyed on the title alone. The retry when an id-keyed search comes
    /// back empty — which means the id is stale or wrong, not that the title
    /// has no subtitles.
    var titleOnly: OpenSubtitlesQuery {
        OpenSubtitlesQuery(text: text, season: season, episode: episode, languages: languages)
    }
}

// MARK: - Domain models

/// One subtitle candidate from a search, flattened to the single file Lume
/// downloads. Multi-CD releases expose several files; only the first is offered
/// because the player loads exactly one sidecar track.
nonisolated struct OnlineSubtitle: Identifiable, Hashable {
    let id: String
    /// The id `/download` takes to mint a (short-lived) download link.
    let fileID: Int
    let languageCode: String
    /// The uploader's release name, e.g. `Fight.Club.1999.REMASTERED.BDRip…`.
    let releaseName: String
    let downloadCount: Int
    let isHearingImpaired: Bool
    let isMachineTranslated: Bool
    let isFromTrusted: Bool
    let rating: Double

    /// The language in the viewer's own language, falling back to the raw code
    /// for OpenSubtitles' regional variants (`pt-br`, `zh-cn`) the system
    /// doesn't name.
    var languageName: String {
        TrackLanguageMatcher.displayName(for: languageCode)
    }
}

/// A language OpenSubtitles indexes subtitles in.
nonisolated struct OpenSubtitlesLanguage: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String {
        code
    }
}

/// The user session minted by `/login`.
nonisolated struct OpenSubtitlesSession: Codable, Equatable {
    var token: String
    var username: String
    /// The host to send subsequent requests to. VIP accounts are moved to their
    /// own host, and using the wrong one costs a redirect on every call.
    var host: String
    var allowedDownloads: Int
}

/// The outcome of a `/download` request: where to fetch the file, and how much
/// of today's allowance is left.
nonisolated struct OpenSubtitlesDownload: Equatable {
    let link: URL
    let fileName: String
    let remainingDownloads: Int
}

// MARK: - Client

nonisolated struct OpenSubtitlesClient {
    static let shared = OpenSubtitlesClient()

    /// The default API host. A signed-in VIP account may be handed a different
    /// one by `/login`; every call takes the host to use as a parameter.
    static let defaultHost = "api.opensubtitles.com"

    private let session: URLSession
    private let apiKey: String?
    /// OpenSubtitles requires a User-Agent naming the app and its version;
    /// generic agents are rejected.
    private let userAgent: String

    init(
        session: URLSession = .shared,
        apiKey: String? = OpenSubtitlesClient.keyFromBundle(),
        userAgent: String = OpenSubtitlesClient.defaultUserAgent()
    ) {
        self.session = session
        self.apiKey = apiKey
        self.userAgent = userAgent
    }

    /// Whether the build carries an API key. When false the integration is
    /// hidden entirely rather than failing at the first request.
    var isConfigured: Bool {
        apiKey != nil
    }

    static func keyFromBundle() -> String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "OpenSubtitlesAPIKey") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Guard against an unsubstituted Info.plist variable (no .env present).
        guard let trimmed, !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    static func defaultUserAgent() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Lume v\(version ?? "1.0")"
    }

    // MARK: - Search

    /// Subtitle candidates for `query`, best-known releases first. Anonymous —
    /// a user token is only needed to download.
    /// Subtitle candidates for `query`.
    ///
    /// An id-keyed search that comes back empty is retried on the title alone.
    /// Empty here does not mean "this title has no subtitles" — it usually means
    /// the catalog's id is stale or points at the wrong feature, and the title
    /// still finds them.
    func search(_ query: OpenSubtitlesQuery, host: String = defaultHost, token: String? = nil) async throws -> [OnlineSubtitle] {
        let results = try await searchOnce(query, host: host, token: token)
        guard results.isEmpty, query.hasIdentifier else { return results }
        let fallback = query.titleOnly
        guard !fallback.isEmpty else { return results }
        return try await searchOnce(fallback, host: host, token: token)
    }

    private func searchOnce(_ query: OpenSubtitlesQuery, host: String, token: String?) async throws -> [OnlineSubtitle] {
        guard isConfigured else { throw OpenSubtitlesError.notConfigured }
        guard !query.isEmpty else { return [] }
        guard let url = Self.searchURL(for: query, host: host) else { throw OpenSubtitlesError.invalidResponse }

        let response: SearchResponse = try await send(makeRequest(url: url, method: "GET", token: token))
        return response.data.compactMap(\.subtitle)
    }

    /// Builds the `/subtitles` URL with its query items sorted by name.
    ///
    /// OpenSubtitles canonicalises the query string and answers 301 for any
    /// other ordering (`x-os-rule: canonical`), so sorting here turns every
    /// search into a single round trip. `static` and non-private so the ordering
    /// contract is unit-testable without a network.
    static func searchURL(for query: OpenSubtitlesQuery, host: String = defaultHost) -> URL? {
        var items: [URLQueryItem] = []
        // An id and a title are never sent together. The id is the precise
        // match, and every extra parameter narrows the result set (the API ANDs
        // them) — a decorated catalog title like "One Battle After Another
        // (2025)" can only take hits away.
        if let identifier = query.identifier {
            items.append(identifier)
        } else if let text = searchText(from: query.text) {
            items.append(URLQueryItem(name: "query", value: text))
        }
        if let season = query.season {
            items.append(URLQueryItem(name: "season_number", value: String(season)))
        }
        if let episode = query.episode {
            items.append(URLQueryItem(name: "episode_number", value: String(episode)))
        }
        if !query.languages.isEmpty {
            // The API wants a comma-separated, sorted list.
            items.append(URLQueryItem(name: "languages", value: query.languages.sorted().joined(separator: ",")))
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v1/subtitles"
        components.queryItems = items.sorted { $0.name < $1.name }
        return components.url
    }

    /// The title to match on, stripped of the decoration IPTV catalogs wrap
    /// around a name and lowercased for the canonical query string.
    ///
    /// The API matches this text closely, so the decoration is not free: for
    /// *One Battle After Another* a trailing `(2025)` — which is exactly how
    /// Xtream catalogs name films — cut the German result set from 846 to 28.
    /// Provider prefixes (`4K | …`, `DE - …`) are worse still. Returns `nil`
    /// when nothing usable is left.
    static func searchText(from raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }

        // Drop a leading provider tag: everything up to the last "|".
        if let separator = text.lastIndex(of: "|") {
            text = String(text[text.index(after: separator)...])
        }
        // Drop a trailing year, bare or parenthesised.
        text = text.replacingOccurrences(
            of: #"[\s\-–—]*[\(\[]?(19|20)\d{2}[\)\]]?\s*$"#,
            with: "",
            options: .regularExpression
        )
        // Collapse the runs of whitespace that stripping can leave behind.
        text = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return text.isEmpty ? nil : text
    }

    /// OpenSubtitles takes IMDb ids as bare digits; the catalogue stores them in
    /// the `tt0137523` form. A non-numeric id is dropped rather than sent as-is,
    /// which the API answers with an empty result set.
    static func normalizedIMDbId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .drop(while: { !$0.isNumber })
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return String(digits)
    }

    // MARK: - Languages

    /// Every language OpenSubtitles indexes, for the search sheet's filter.
    func languages(host: String = defaultHost) async throws -> [OpenSubtitlesLanguage] {
        guard isConfigured else { throw OpenSubtitlesError.notConfigured }
        guard let url = URL(string: "https://\(host)/api/v1/infos/languages") else {
            throw OpenSubtitlesError.invalidResponse
        }
        let response: LanguagesResponse = try await send(makeRequest(url: url, method: "GET", token: nil))
        return response.data.map { OpenSubtitlesLanguage(code: $0.languageCode, name: $0.languageName) }
    }

    // MARK: - Account

    /// Exchanges account credentials for a user token.
    func login(username: String, password: String, host: String = defaultHost) async throws -> OpenSubtitlesSession {
        guard isConfigured else { throw OpenSubtitlesError.notConfigured }
        guard let url = URL(string: "https://\(host)/api/v1/login") else {
            throw OpenSubtitlesError.invalidResponse
        }
        var request = makeRequest(url: url, method: "POST", token: nil)
        request.httpBody = try? JSONEncoder().encode(LoginRequest(username: username, password: password))

        let response: LoginResponse = try await send(request)
        return OpenSubtitlesSession(
            token: response.token,
            username: username,
            // `base_url` arrives bare (`api.opensubtitles.com`) but tolerate a
            // full URL in case that ever changes.
            host: response.baseURL.map { $0.replacingOccurrences(of: "https://", with: "") } ?? host,
            allowedDownloads: response.user?.allowedDownloads ?? 0
        )
    }

    /// Invalidates the user token server-side. Best-effort — the caller drops
    /// the local session either way.
    func logout(session: OpenSubtitlesSession) async throws {
        guard let url = URL(string: "https://\(session.host)/api/v1/logout") else { return }
        let _: EmptyBody = try await send(makeRequest(url: url, method: "DELETE", token: session.token))
    }

    // MARK: - Download

    /// Mints a short-lived link for `subtitle`, converted to SubRip so every
    /// engine can parse it (uploads are also ASS/SSA/SUB, which the sidecar
    /// paths handle less uniformly).
    func downloadLink(for subtitle: OnlineSubtitle, session: OpenSubtitlesSession) async throws -> OpenSubtitlesDownload {
        guard isConfigured else { throw OpenSubtitlesError.notConfigured }
        guard let url = URL(string: "https://\(session.host)/api/v1/download") else {
            throw OpenSubtitlesError.invalidResponse
        }
        var request = makeRequest(url: url, method: "POST", token: session.token)
        request.httpBody = try? JSONEncoder().encode(DownloadRequest(fileID: subtitle.fileID, subFormat: "srt"))

        let response: DownloadResponse = try await send(request)
        guard let link = URL(string: response.link) else { throw OpenSubtitlesError.invalidResponse }
        return OpenSubtitlesDownload(
            link: link,
            fileName: response.fileName ?? "\(subtitle.id).srt",
            remainingDownloads: response.remaining ?? 0
        )
    }

    /// Fetches the subtitle file itself. The link is pre-signed, so it carries
    /// no API key or token.
    func fetch(_ download: OpenSubtitlesDownload) async throws -> Data {
        let (data, response) = try await session.data(from: download.link)
        guard let http = response as? HTTPURLResponse else { throw OpenSubtitlesError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else { throw OpenSubtitlesError.server(http.statusCode) }
        guard !data.isEmpty else { throw OpenSubtitlesError.invalidResponse }
        return data
    }

    // MARK: - Networking

    private func makeRequest(url: URL, method: String, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenSubtitlesError.invalidResponse }

        guard (200 ... 299).contains(http.statusCode) else {
            switch http.statusCode {
            case 401 where request.url?.lastPathComponent == "login":
                throw OpenSubtitlesError.invalidCredentials
            case 401, 403:
                throw OpenSubtitlesError.notAuthenticated
            case 406, 429:
                // 406 is the documented "download quota reached"; 429 is the
                // rate limiter, which reads the same way to the viewer.
                throw OpenSubtitlesError.quotaExceeded
            default:
                throw OpenSubtitlesError.server(http.statusCode)
            }
        }

        // `/logout` answers with an empty body.
        if data.isEmpty, let empty = EmptyBody() as? T { return empty }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OpenSubtitlesError.decoding
        }
    }
}

// MARK: - Wire format

//
// Flattened rather than nested inside their responses: SwiftLint caps nesting
// at one level, and a `CodingKeys` enum already spends that level.

private nonisolated struct EmptyBody: Decodable {}

private nonisolated struct LoginRequest: Encodable {
    let username: String
    let password: String
}

private nonisolated struct LoginUserDTO: Decodable {
    let allowedDownloads: Int?

    enum CodingKeys: String, CodingKey {
        case allowedDownloads = "allowed_downloads"
    }
}

private nonisolated struct LoginResponse: Decodable {
    let token: String
    let baseURL: String?
    let user: LoginUserDTO?

    enum CodingKeys: String, CodingKey {
        case token
        case baseURL = "base_url"
        case user
    }
}

private nonisolated struct DownloadRequest: Encodable {
    let fileID: Int
    let subFormat: String

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case subFormat = "sub_format"
    }
}

private nonisolated struct DownloadResponse: Decodable {
    let link: String
    let fileName: String?
    let remaining: Int?

    enum CodingKeys: String, CodingKey {
        case link
        case fileName = "file_name"
        case remaining
    }
}

private nonisolated struct LanguageDTO: Decodable {
    let languageCode: String
    let languageName: String

    enum CodingKeys: String, CodingKey {
        case languageCode = "language_code"
        case languageName = "language_name"
    }
}

private nonisolated struct LanguagesResponse: Decodable {
    let data: [LanguageDTO]
}

/// One downloadable file of a subtitle record. Multi-CD releases list several.
nonisolated struct OpenSubtitlesFileDTO: Decodable {
    let fileID: Int?
    let fileName: String?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileName = "file_name"
    }
}

/// The per-record fields the picker shows. The rest of each record (uploader,
/// related links, legacy ids) is ignored.
nonisolated struct OpenSubtitlesAttributesDTO: Decodable {
    let subtitleID: String?
    let language: String?
    let downloadCount: Int?
    let hearingImpaired: Bool?
    let machineTranslated: Bool?
    let aiTranslated: Bool?
    let fromTrusted: Bool?
    let ratings: Double?
    let release: String?
    let files: [OpenSubtitlesFileDTO]?

    enum CodingKeys: String, CodingKey {
        case subtitleID = "subtitle_id"
        case language
        case downloadCount = "download_count"
        case hearingImpaired = "hearing_impaired"
        case machineTranslated = "machine_translated"
        case aiTranslated = "ai_translated"
        case fromTrusted = "from_trusted"
        case ratings
        case release
        case files
    }
}

/// One `/subtitles` record.
nonisolated struct OpenSubtitlesSearchItem: Decodable {
    let attributes: OpenSubtitlesAttributesDTO

    /// `nil` for a record with no downloadable file or no language — neither can
    /// be offered to the viewer, and both appear occasionally in the feed.
    var subtitle: OnlineSubtitle? {
        guard let file = attributes.files?.first, let fileID = file.fileID,
              let language = attributes.language, !language.isEmpty
        else { return nil }
        return OnlineSubtitle(
            id: attributes.subtitleID ?? String(fileID),
            fileID: fileID,
            languageCode: language,
            releaseName: attributes.release ?? file.fileName ?? "",
            downloadCount: attributes.downloadCount ?? 0,
            isHearingImpaired: attributes.hearingImpaired ?? false,
            isMachineTranslated: (attributes.machineTranslated ?? false) || (attributes.aiTranslated ?? false),
            isFromTrusted: attributes.fromTrusted ?? false,
            rating: attributes.ratings ?? 0
        )
    }
}

private nonisolated struct SearchResponse: Decodable {
    let data: [OpenSubtitlesSearchItem]
}

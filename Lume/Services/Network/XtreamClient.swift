//
//  XtreamClient.swift
//  Lume
//
//  Xtream Codes API client
//

import Foundation
import OSLog

enum XtreamError: LocalizedError {
    case invalidURL
    case authenticationFailed
    case networkError(Error)
    case decodingError(Error)
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The server URL is invalid."
        case .authenticationFailed:
            "Authentication failed. The provider rejected the request (this can also happen when the account's connection limit is reached)."
        case let .networkError(error):
            "Network error: \(error.localizedDescription)"
        case let .decodingError(error):
            "Failed to read the server response: \(error.localizedDescription)"
        case .invalidResponse:
            "Received an invalid response from the server."
        case let .serverError(code):
            "Server error (HTTP \(code))."
        }
    }

    /// Whether the failure is likely transient and worth retrying.
    /// Note: `authenticationFailed` (HTTP 401/403) is *not* retriable by
    /// default — for login it means bad credentials. During an
    /// already-authenticated sync it's usually the provider's connection /
    /// rate limit, so those call sites opt in via `retryAuthFailure`.
    var isRetriable: Bool {
        switch self {
        case .networkError:
            // Timeouts, connection reset (RST), lost connection — transient.
            true
        case let .serverError(code):
            code >= 500
        case .invalidURL, .authenticationFailed, .decodingError, .invalidResponse:
            false
        }
    }

    var isAuthFailure: Bool {
        if case .authenticationFailed = self { return true }
        return false
    }
}

// MARK: - XtreamClient

class XtreamClient: APIClient {
    nonisolated struct Configuration {
        let serverURL: String
        let username: String
        let password: String
        let timeout: TimeInterval

        init(serverURL: String, username: String, password: String, timeout: TimeInterval = 30) {
            self.serverURL = serverURL
            self.username = username
            self.password = password
            self.timeout = timeout
        }
    }

    let configuration: Configuration
    let session: URLSession

    nonisolated init(configuration: Configuration, urlSession: URLSession? = nil) {
        self.configuration = configuration
        session = urlSession ?? Self.makeSession(timeout: configuration.timeout)
    }

    /// Convenience initializer for backward compatibility
    convenience nonisolated init(urlSession: URLSession? = nil) {
        let config = Configuration(
            serverURL: "",
            username: "",
            password: "",
            timeout: 30
        )
        self.init(configuration: config, urlSession: urlSession)
    }

    /// Builds a dedicated session for Xtream API calls.
    ///
    /// Uses a single connection per host: many Xtream providers cap an account
    /// to one concurrent connection and reject extra requests with 401/403.
    /// Serializing connections (instead of reusing `.shared`'s pool, which the
    /// server may RST after a heavy transfer) avoids tripping that limit. Also
    /// applies the configured timeout, which was previously ignored.
    private nonisolated static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }

    // MARK: - Helper Methods

    private func buildURL(serverURL: String, path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: serverURL)
        // Ensure the path is appended properly
        if !(components?.path.hasSuffix("/") ?? false), !path.hasPrefix("/") {
            components?.path.append("/")
        }
        components?.path.append(path)

        let existingItems = components?.queryItems ?? []
        components?.queryItems = existingItems + queryItems

        return components?.url
    }

    /// Maximum number of attempts (1 initial + retries) for a single request.
    private static let maxAttempts = 3

    /// Performs a request with retry-and-backoff for transient failures.
    ///
    /// - Parameter retryAuthFailure: when `true`, HTTP 401/403 is also treated
    ///   as transient. Sync/content calls set this because, after `getInfo`
    ///   has already proven the credentials, a 401/403 is almost always the
    ///   provider's connection/rate limit rather than bad credentials. Login
    ///   (`getInfo`) leaves it `false` so wrong credentials fail fast.
    private func request<T: Decodable>(_ url: URL, retryAuthFailure: Bool = true) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await performRequest(url)
            } catch let error as XtreamError {
                let retriable = error.isRetriable || (retryAuthFailure && error.isAuthFailure)
                guard retriable, attempt < Self.maxAttempts else { throw error }

                // Exponential backoff: 2s, then 4s. Gives the provider time to
                // release the connection slot / clear the rate-limit window.
                let delay = pow(2.0, Double(attempt))
                Logger.network.warning(
                    "Xtream request failed (\(error.localizedDescription)); retry \(attempt)/\(Self.maxAttempts - 1) in \(delay)s"
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// A single request attempt. Network-level failures are wrapped into
    /// `XtreamError.networkError` so callers see a consistent error type.
    private func performRequest<T: Decodable>(_ url: URL) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw XtreamError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw XtreamError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw XtreamError.authenticationFailed
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw XtreamError.serverError(httpResponse.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            throw XtreamError.decodingError(error)
        }
    }

    // MARK: - API Methods

    /// 1. Get Server and User Info
    func getInfo(playlist: Playlist) async throws -> XtreamAuthResponse {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password)
        ]

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        // Login: a 401/403 means bad credentials, so don't retry it.
        return try await request(url, retryAuthFailure: false)
    }

    /// 2. Get Live Categories
    func getLiveCategories(playlist: Playlist) async throws -> [XtreamCategory] {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_live_categories")
        ]

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        return try await request(url)
    }

    /// 3. Get Live Streams
    func getLiveStreams(playlist: Playlist, categoryId: String? = nil) async throws -> [XtreamLiveStream] {
        var queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_live_streams")
        ]
        if let categoryId {
            queryItems.append(URLQueryItem(name: "category_id", value: categoryId))
        }

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        return try await request(url)
    }

    /// 4. Get VOD Categories
    func getVODCategories(playlist: Playlist) async throws -> [XtreamCategory] {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_vod_categories")
        ]

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        return try await request(url)
    }

    /// 5. Get VOD Streams
    func getVODStreams(playlist: Playlist, categoryId: String? = nil) async throws -> [XtreamVODStream] {
        var queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_vod_streams")
        ]
        if let categoryId {
            queryItems.append(URLQueryItem(name: "category_id", value: categoryId))
        }

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        return try await request(url)
    }

    /// 6. Get VOD Info
    func getVODInfo(playlist: Playlist, vodId: Int) async throws -> XtreamVODInfo {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_vod_info"),
            URLQueryItem(name: "vod_id", value: String(vodId))
        ]

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        return try await request(url)
    }

    /// 7. Get Series Categories
    func getSeriesCategories(playlist: Playlist) async throws -> [XtreamCategory] {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_series_categories")
        ]

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        return try await request(url)
    }

    /// 8. Get Series
    func getSeries(playlist: Playlist, categoryId: String? = nil) async throws -> [XtreamSeries] {
        var queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_series")
        ]
        if let categoryId {
            queryItems.append(URLQueryItem(name: "category_id", value: categoryId))
        }

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        return try await request(url)
    }

    /// 9. Get Series Info
    func getSeriesInfo(playlist: Playlist, seriesId: Int) async throws -> XtreamSeriesInfoResponse {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_series_info"),
            URLQueryItem(name: "series_id", value: String(seriesId))
        ]

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        return try await request(url)
    }

    /// 10. Get Short EPG
    func getShortEPG(playlist: Playlist, streamId: Int, limit: Int? = nil) async throws -> [XtreamShortEPG] {
        var queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_short_epg"),
            URLQueryItem(name: "stream_id", value: String(streamId))
        ]
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        struct ShortEPGResponse: Decodable {
            let epgListings: [XtreamShortEPG]
        }

        do {
            let response: ShortEPGResponse = try await request(url)
            return response.epgListings
        } catch {
            // Try array fallback if not wrapped
            if let arrayResponse: [XtreamShortEPG] = try? await request(url) {
                return arrayResponse
            }
            throw error
        }
    }

    /// 11. Get XMLTV — download to temp file, then stream-parse in batches.
    /// Returns the local file URL so the caller can parse incrementally.
    func downloadXMLTV(playlist: Playlist) async throws -> URL {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password)
        ]

        guard let url = buildURL(serverURL: playlist.serverURL, path: "xmltv.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await session.download(from: url)
        } catch {
            throw XtreamError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw XtreamError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw XtreamError.serverError(httpResponse.statusCode)
        }

        // Move to a stable location before the system cleans it up
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xmltv")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    // MARK: - Stream URL Building

    /// Builds a playback URL for a movie
    func buildMovieURL(for movie: Movie, playlist: Playlist) -> URL? {
        let ext = movie.containerExtension ?? "mp4"
        return URL(string: "\(playlist.serverURL)/movie/\(playlist.username)/\(playlist.password)/\(movie.streamId).\(ext)")
    }

    /// Builds a playback URL for an episode
    func buildEpisodeURL(for episode: Episode, playlist: Playlist) -> URL? {
        let ext = episode.containerExtension
        return URL(string: "\(playlist.serverURL)/series/\(playlist.username)/\(playlist.password)/\(episode.episodeId).\(ext)")
    }

    /// Builds a playback URL for a live stream
    func buildLiveStreamURL(for stream: LiveStream, playlist: Playlist, format: StreamFormat = .m3u8) -> URL? {
        URL(string: "\(playlist.serverURL)/live/\(playlist.username)/\(playlist.password)/\(stream.streamId).\(format.rawValue)")
    }

    /// Builds a catchup/timeshift URL for a live stream
    func buildCatchupURL(for stream: LiveStream, playlist: Playlist, startTime: Date, duration: TimeInterval = 3600) -> URL? {
        let timestamp = Int(startTime.timeIntervalSince1970)
        let durationInt = Int(duration)
        return URL(string: "\(playlist.serverURL)/timeshift/\(playlist.username)/\(playlist.password)/\(durationInt)/\(timestamp)/\(stream.streamId).m3u8")
    }
}

// MARK: - XMLTV Parser

/// A parsed XMLTV programme ready for direct insertion.
struct ParsedProgramme {
    let channelId: String
    let title: String
    let description: String
    let start: Date
    let end: Date
}

/// Streaming SAX parser that yields batches via a callback to keep memory flat.
final nonisolated class XMLTVParser: NSObject, XMLParserDelegate {
    private var batch: [ParsedProgramme] = []
    private let batchSize: Int
    private let onBatch: ([ParsedProgramme]) -> Void
    private(set) var totalCount: Int = 0

    private var currentStart: String?
    private var currentStop: String?
    private var currentChannel: String?
    private var currentTitle: String?
    private var currentDesc: String?
    private var currentText: String = ""

    private static let xmltvDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    init(batchSize: Int = 2000, onBatch: @escaping ([ParsedProgramme]) -> Void) {
        self.batchSize = batchSize
        self.onBatch = onBatch
    }

    /// Parse an XMLTV file from disk, calling `onBatch` for every `batchSize` programmes.
    static func parse(fileURL: URL, batchSize: Int = 2000, onBatch: @escaping ([ParsedProgramme]) -> Void) -> Int {
        guard let xmlParser = XMLParser(contentsOf: fileURL) else { return 0 }
        let delegate = XMLTVParser(batchSize: batchSize, onBatch: onBatch)
        xmlParser.delegate = delegate
        xmlParser.parse()
        // Flush remaining
        if !delegate.batch.isEmpty {
            onBatch(delegate.batch)
        }
        return delegate.totalCount
    }

    func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes attributeDict: [String: String] = [:]) {
        currentText = ""
        if elementName == "programme" {
            currentStart = attributeDict["start"]
            currentStop = attributeDict["stop"]
            currentChannel = attributeDict["channel"]
            currentTitle = nil
            currentDesc = nil
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        if elementName == "programme" {
            if let startDate = Self.xmltvDate(currentStart),
               let endDate = Self.xmltvDate(currentStop),
               let channel = currentChannel,
               let title = currentTitle, !title.isEmpty
            {
                batch.append(ParsedProgramme(
                    channelId: channel,
                    title: title,
                    description: currentDesc ?? "",
                    start: startDate,
                    end: endDate
                ))
                totalCount += 1

                if batch.count >= batchSize {
                    onBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            currentStart = nil
            currentStop = nil
            currentChannel = nil
            currentTitle = nil
            currentDesc = nil
        } else if elementName == "title" {
            currentTitle = (currentTitle ?? "") + currentText
        } else if elementName == "desc" {
            currentDesc = (currentDesc ?? "") + currentText
        }
    }

    private static func xmltvDate(_ dateString: String?) -> Date? {
        guard let dateString, !dateString.isEmpty else { return nil }
        return xmltvDateFormatter.date(from: dateString)
    }
}

// MARK: - Supporting Types

enum StreamFormat: String {
    case m3u8
    case tsStream = "ts"
}

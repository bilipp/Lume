//
//  StremioClient.swift
//  Lume
//
//  Stremio addon HTTP client. Loads an addon from its `manifest.json` URL and
//  speaks the Stremio Addon Protocol's resource endpoints — catalog, meta,
//  stream and subtitles — all simple GET-JSON requests off the addon's base
//  URL. Mirrors the shape and retry behaviour of `XtreamClient` /
//  `StalkerClient`.
//

import Foundation
import OSLog

class StremioClient {
    nonisolated struct Configuration {
        /// The full, normalized manifest URL (ending in `/manifest.json`).
        let manifestURL: String
        let timeout: TimeInterval

        init(manifestURL: String, timeout: TimeInterval = 30) {
            self.manifestURL = manifestURL
            self.timeout = timeout
        }

        /// A configuration built from a playlist's stored fields — the manifest
        /// URL lives in `serverURL`.
        init(playlist: Playlist, timeout: TimeInterval = 30) {
            self.init(manifestURL: playlist.serverURL, timeout: timeout)
        }
    }

    let configuration: Configuration
    let session: URLSession

    nonisolated init(configuration: Configuration, urlSession: URLSession? = nil) {
        self.configuration = configuration
        session = urlSession ?? Self.makeSession(timeout: configuration.timeout)
    }

    private nonisolated static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 120
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }

    // MARK: - URL construction

    /// Builds a resource URL off an addon base:
    /// `{base}/{resource}/{type}/{id}.json`, with catalog extras encoded as a
    /// query-string-shaped path segment before `.json`
    /// (`{base}/catalog/movie/top/genre=Action&skip=100.json`).
    nonisolated static func resourceURL(
        base: URL,
        resource: String,
        type: String,
        id: String,
        extras: [(name: String, value: String)] = []
    ) -> URL? {
        // `URLComponents.path` percent-encodes segments on serialization, but a
        // path built with `appendingPathComponent` would also encode the `=`
        // and `&` the extras segment needs verbatim — so assemble the encoded
        // path manually.
        guard let encodedId = id.addingPercentEncoding(withAllowedCharacters: .stremioPathSegment) else {
            return nil
        }
        var path = "/\(resource)/\(type)/\(encodedId)"
        if !extras.isEmpty {
            let encoded = extras.compactMap { extra -> String? in
                guard let value = extra.value.addingPercentEncoding(withAllowedCharacters: .stremioPathSegment) else {
                    return nil
                }
                return "\(extra.name)=\(value)"
            }
            guard encoded.count == extras.count else { return nil }
            path += "/\(encoded.joined(separator: "&"))"
        }
        return URL(string: base.absoluteString + path + ".json")
    }

    private nonisolated func url(
        resource: String,
        type: String,
        id: String,
        extras: [(name: String, value: String)] = []
    ) throws -> URL {
        guard let base = StremioManifestURL.baseURL(of: configuration.manifestURL),
              let url = Self.resourceURL(base: base, resource: resource, type: type, id: id, extras: extras)
        else { throw StremioError.invalidURL }
        return url
    }

    // MARK: - Request plumbing

    private static let maxAttempts = 3

    /// Issues a GET for the given URL with backoff on transient failures.
    private func request<T: Decodable>(_ url: URL) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await perform(url: url)
            } catch let error as StremioError {
                guard error.isRetriable, attempt < Self.maxAttempts else { throw error }
                let delay = pow(2.0, Double(attempt))
                Logger.network.warning(
                    "Stremio request failed (\(error.localizedDescription)); retry \(attempt)/\(Self.maxAttempts - 1) in \(delay)s"
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// A single request attempt, mapping transport/HTTP failures onto
    /// `StremioError`.
    private func perform<T: Decodable>(url: URL) async throws -> T {
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw StremioError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StremioError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw StremioError.serverError(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw StremioError.decodingError(error)
        }
    }

    // MARK: - Manifest

    /// Loads the addon's manifest. Doubles as the add-playlist connection test.
    func getManifest() async throws -> StremioManifest {
        guard let url = URL(string: StremioManifestURL.normalized(configuration.manifestURL)) else {
            throw StremioError.invalidURL
        }
        do {
            return try await request(url)
        } catch let error as StremioError where !error.isRetriable {
            switch error {
            case .decodingError, .invalidResponse, .serverError:
                throw StremioError.manifestUnavailable
            default:
                throw error
            }
        }
    }

    // MARK: - Resources

    /// One page of a catalog. `skip` pages in steps of the protocol's page
    /// size (100); a page shorter than that marks the end of the catalog.
    func getCatalog(type: String, id: String, skip: Int = 0) async throws -> StremioCatalogResponse {
        let extras: [(name: String, value: String)] = skip > 0 ? [("skip", String(skip))] : []
        return try await request(url(resource: "catalog", type: type, id: id, extras: extras))
    }

    /// Full metadata for a title — for series this carries the episode list.
    func getMeta(type: String, id: String) async throws -> StremioMetaResponse {
        try await request(url(resource: "meta", type: type, id: id))
    }

    /// Playable stream candidates for a meta or video id.
    func getStreams(type: String, id: String) async throws -> StremioStreamResponse {
        try await request(url(resource: "stream", type: type, id: id))
    }

    /// Subtitle tracks for a meta or video id.
    func getSubtitles(type: String, id: String) async throws -> StremioSubtitlesResponse {
        try await request(url(resource: "subtitles", type: type, id: id))
    }
}

private extension CharacterSet {
    /// Characters left verbatim inside a Stremio path segment — unreserved
    /// characters only, so ids with `:` (episode ids) and extra values with
    /// spaces or `&` are percent-encoded.
    nonisolated static let stremioPathSegment = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

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

/// Read-only TMDB API client. Only the endpoints the home screen needs are
/// implemented (trending). Mirrors `XtreamClient`'s direct async/await style.
struct TMDBClient {
    static let shared = TMDBClient()

    enum MediaType: String {
        case movie
        case tv
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

    /// Returns the TMDB IDs of trending titles in popularity order.
    func trendingIDs(_ media: MediaType, timeWindow: TimeWindow = .week) async throws -> [Int] {
        let response: TrendingResponse = try await get("/trending/\(media.rawValue)/\(timeWindow.rawValue)")
        return response.results.map(\.id)
    }

    /// Returns trending titles enriched with the artwork and copy the home hero
    /// carousel needs (backdrop, title, overview), in popularity order.
    func trending(_ media: MediaType, timeWindow: TimeWindow = .week) async throws -> [TrendingTitle] {
        let response: TrendingResponse = try await get("/trending/\(media.rawValue)/\(timeWindow.rawValue)")
        return response.results.map {
            TrendingTitle(
                id: $0.id,
                title: $0.title ?? $0.name ?? "",
                overview: $0.overview ?? "",
                backdropPath: $0.backdropPath
            )
        }
    }

    /// Builds a full image URL from a TMDB relative path (e.g. `/abc.jpg`).
    /// `w1280` is the widescreen backdrop size used by the hero carousel.
    static func backdropURL(_ path: String?, size: String = "w1280") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBaseURL + size + path)
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
        guard (200...299).contains(http.statusCode) else {
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
struct TrendingTitle: Sendable, Identifiable, Hashable {
    let id: Int
    let title: String
    let overview: String
    let backdropPath: String?
}

// MARK: - DTOs

private struct TrendingResponse: Decodable {
    struct Item: Decodable {
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
    let results: [Item]
}

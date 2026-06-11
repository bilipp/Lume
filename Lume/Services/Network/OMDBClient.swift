//
//  OMDBClient.swift
//  Lume
//
//  Lightweight read-only client for the OMDb API (https://www.omdbapi.com).
//  Used to fetch aggregator ratings (IMDb, Rotten Tomatoes, Metacritic) for a
//  title, keyed by its IMDb id, to enrich the detail screens beyond TMDB's
//  single vote average.
//
//  The API key lives in the git-ignored `.env` file (OMDB_API_KEY) and is
//  injected into Info.plist at build time by Scripts/inject-env.sh — it is
//  never committed to source control.
//

import Foundation

enum OMDBError: Error {
    case missingKey
    case invalidURL
    case invalidResponse
    case serverError(Int)
    case notFound
    case decodingError(Error)
}

/// Read-only OMDb client. Only the ratings lookup the detail screens need is
/// implemented.
nonisolated struct OMDBClient {
    static let shared = OMDBClient()

    private let baseURL = "https://www.omdbapi.com/"
    private let session: URLSession
    private let key: String?

    init(
        session: URLSession = .shared,
        key: String? = OMDBClient.keyFromBundle()
    ) {
        self.session = session
        self.key = key
    }

    /// Whether a usable API key is present. When false the ratings section is
    /// simply hidden rather than surfacing an error to the user.
    var isConfigured: Bool {
        guard let key, !key.isEmpty else { return false }
        // Guard against an unsubstituted Info.plist variable (no .env present).
        return !key.hasPrefix("$(")
    }

    static func keyFromBundle() -> String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "OMDBAPIKey") as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetches the aggregator ratings (IMDb, Rotten Tomatoes, Metacritic) for a
    /// title by its IMDb id (e.g. `tt3896198`). Sources OMDb returns that we
    /// don't recognise are dropped; the order from OMDb is preserved.
    func ratings(imdbId: String) async throws -> [ExternalRating] {
        guard isConfigured, let key else { throw OMDBError.missingKey }
        let trimmed = imdbId.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw OMDBError.notFound }

        var components = URLComponents(string: baseURL)
        components?.queryItems = [
            URLQueryItem(name: "i", value: trimmed),
            URLQueryItem(name: "apikey", value: key)
        ]
        guard let url = components?.url else { throw OMDBError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OMDBError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw OMDBError.serverError(http.statusCode)
        }

        let decoded: OMDBResponse
        do {
            decoded = try JSONDecoder().decode(OMDBResponse.self, from: data)
        } catch {
            throw OMDBError.decodingError(error)
        }

        // OMDb signals a miss with `"Response": "False"` and HTTP 200.
        guard decoded.response?.lowercased() == "true" else {
            throw OMDBError.notFound
        }

        return OMDBClient.mapRatings(decoded.ratings ?? [])
    }

    /// Maps OMDb's free-text rating entries to our known sources, dropping
    /// unrecognised ones and de-duplicating by source (first wins).
    static func mapRatings(_ entries: [OMDBRatingEntry]) -> [ExternalRating] {
        var seen = Set<ExternalRating.Source>()
        var result: [ExternalRating] = []
        for entry in entries {
            guard let source = ExternalRating.Source(omdbSource: entry.source),
                  !entry.value.isEmpty,
                  !seen.contains(source) else { continue }
            seen.insert(source)
            result.append(ExternalRating(source: source, value: entry.value))
        }
        return result
    }
}

// MARK: - DTOs

/// The subset of the OMDb title response we decode.
nonisolated struct OMDBResponse: Decodable {
    let response: String?
    let ratings: [OMDBRatingEntry]?

    enum CodingKeys: String, CodingKey {
        case response = "Response"
        case ratings = "Ratings"
    }
}

/// One `{ "Source": …, "Value": … }` entry from OMDb's `Ratings` array.
nonisolated struct OMDBRatingEntry: Decodable {
    let source: String
    let value: String

    enum CodingKeys: String, CodingKey {
        case source = "Source"
        case value = "Value"
    }
}

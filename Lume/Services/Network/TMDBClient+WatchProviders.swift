//
//  TMDBClient+WatchProviders.swift
//  Lume
//
//  Watch-provider (streaming service) decoding for TMDB. The per-title flatrate
//  offers ride along on the title-detail requests via `append_to_response`; the
//  region's full provider list (for the Settings picker) comes from a dedicated
//  endpoint. Split out of TMDBClient.swift to keep that file within the size cap.
//

import Foundation

// MARK: - Requests

nonisolated extension TMDBClient {
    /// The ISO 3166-1 region code (e.g. `US`, `DE`) for the user's current
    /// locale, used as the `watch_region` for watch-provider lookups. Falls
    /// back to `US` when the locale carries no region.
    static func preferredRegionCode() -> String {
        Locale.current.region?.identifier ?? "US"
    }

    /// Builds a full watch-provider logo URL from a TMDB relative path. Provider
    /// logos are small square marks (e.g. the Netflix "N"), so a modest size
    /// keeps the browse tiles crisp without over-fetching.
    static func providerLogoURL(_ path: String?, size: String = "w92") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBaseURL + size + path)
    }

    /// The streaming services available in the user's region for the given media
    /// type, ordered by TMDB's display priority. Powers the watch-provider
    /// picker in Settings and supplies the names/logos the browse tiles render.
    func watchProviderList(_ media: MediaType) async throws -> [WatchProviderInfo] {
        let response: WatchProviderListResponse = try await get(
            "/watch/providers/\(media.rawValue)?watch_region=\(region)"
        )
        return response.results
            .map {
                WatchProviderInfo(
                    id: $0.providerId,
                    name: $0.providerName ?? "",
                    logoPath: $0.logoPath,
                    displayPriority: $0.displayPriorities?[region] ?? $0.displayPriority ?? .max
                )
            }
            .filter { !$0.name.isEmpty }
            .sorted { $0.displayPriority < $1.displayPriority }
    }
}

// MARK: - Public types

/// A streaming service from TMDB's watch-providers list, used to populate the
/// local provider catalog the picker and browse tiles read.
nonisolated struct WatchProviderInfo: Hashable {
    let id: Int
    let name: String
    let logoPath: String?
    let displayPriority: Int
}

// MARK: - DTOs

/// TMDB's appended `watch/providers` payload: per-country offers keyed by ISO
/// 3166-1 region. Only the `flatrate` (subscription) offers are decoded.
nonisolated struct WatchProvidersEntry: Decodable {
    let results: [String: WatchProviderCountryOffers]
}

nonisolated struct WatchProviderCountryOffers: Decodable {
    let flatrate: [WatchProviderOffer]?
}

nonisolated struct WatchProviderOffer: Decodable {
    let providerId: Int
    let displayPriority: Int?
    enum CodingKeys: String, CodingKey {
        case providerId = "provider_id"
        case displayPriority = "display_priority"
    }
}

/// `/watch/providers/{movie,tv}` — the full provider list for a region.
nonisolated struct WatchProviderListResponse: Decodable {
    let results: [WatchProviderListEntry]
}

nonisolated struct WatchProviderListEntry: Decodable {
    let providerId: Int
    let providerName: String?
    let logoPath: String?
    let displayPriority: Int?
    let displayPriorities: [String: Int]?
    enum CodingKeys: String, CodingKey {
        case providerId = "provider_id"
        case providerName = "provider_name"
        case logoPath = "logo_path"
        case displayPriority = "display_priority"
        case displayPriorities = "display_priorities"
    }
}

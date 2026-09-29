//
//  XtreamClient+Digest.swift
//  Lume
//
//  Fetches of the three bulk catalog endpoints that skip the decode when the
//  response is byte-identical to the one last imported.
//
//  Xtream panels send no ETag, Last-Modified or compression, so a conditional
//  GET is impossible and the download itself is irreducible. What a match
//  saves is everything after it: a real 280k-row provider spent about 18 s on
//  a Mac decoding, comparing and sweeping a catalog that had not changed.
//

import CryptoKit
import Foundation

/// A bulk fetch that may have found the payload unchanged.
nonisolated enum XtreamFetch<Value: Sendable> {
    /// The response hashed to the digest the caller already holds.
    case unchanged
    /// A new payload, with the SHA-256 digest of its bytes.
    case fetched(Value, digest: String)

    func map<Mapped: Sendable>(_ transform: (Value) -> Mapped) -> XtreamFetch<Mapped> {
        switch self {
        case .unchanged: .unchanged
        case let .fetched(value, digest): .fetched(transform(value), digest: digest)
        }
    }
}

extension XtreamClient {
    func getVODStreamsIfChanged(playlist: Playlist, knownDigest: String?) async throws -> XtreamFetch<[XtreamVODStream]> {
        let fetch: XtreamFetch<XtreamList<XtreamVODStream>> = try await fetchIfChanged(
            action: "get_vod_streams", playlist: playlist, knownDigest: knownDigest,
            phases: RequestPhases(fetch: .xtreamFetchMovies, decode: .xtreamDecodeMovies)
        )
        return fetch.map(\.items)
    }

    func getSeriesIfChanged(playlist: Playlist, knownDigest: String?) async throws -> XtreamFetch<[XtreamSeries]> {
        let fetch: XtreamFetch<XtreamList<XtreamSeries>> = try await fetchIfChanged(
            action: "get_series", playlist: playlist, knownDigest: knownDigest,
            phases: RequestPhases(fetch: .xtreamFetchSeries, decode: .xtreamDecodeSeries)
        )
        return fetch.map(\.items)
    }

    func getLiveStreamsIfChanged(playlist: Playlist, knownDigest: String?) async throws -> XtreamFetch<[XtreamLiveStream]> {
        let fetch: XtreamFetch<XtreamList<XtreamLiveStream>> = try await fetchIfChanged(
            action: "get_live_streams", playlist: playlist, knownDigest: knownDigest,
            phases: RequestPhases(fetch: .xtreamFetchLiveStreams, decode: .xtreamDecodeLiveStreams)
        )
        return fetch.map(\.items)
    }

    private func fetchIfChanged<T: Decodable & Sendable>(
        action: String,
        playlist: Playlist,
        knownDigest: String?,
        phases: RequestPhases
    ) async throws -> XtreamFetch<T> {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: action)
        ]
        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }
        return try await withRetries(action: action) {
            let (data, response) = try await fetchValidated(url, action: action, phases: phases)
            let digest = await Self.sha256Hex(of: data)
            if digest == knownDigest { return .unchanged }
            let value = try await decodeResponse(T.self, data: data, response: response, action: action, phases: phases)
            return .fetched(value, digest: digest)
        }
    }

    /// Off every actor, like the decode it can replace: about 0.1 s for a
    /// 66 MB payload.
    @concurrent
    static func sha256Hex(of data: Data) async -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

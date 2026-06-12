//
//  IntroDBClient.swift
//  Lume
//
//  Read-only client for IntroDB (https://introdb.app), which crowd-sources
//  intro / recap / outro timestamps for TV episodes, keyed by the *series'*
//  IMDb id plus season and episode. Used to offer an in-player "Skip Intro"
//  button (see `PlayerSkipIntroOverlay`).
//
//  IntroDB's read endpoint needs no authentication. The optional API key lives
//  in the git-ignored `.env` file (INTRO_DB_API_KEY) and is injected into
//  Info.plist at build time by Scripts/inject-env.sh — never committed. It is
//  attached as `X-API-Key` when present (harmless for reads, and ready for a
//  future submit flow); its absence never disables the skip feature.
//

import Foundation

enum IntroDBError: Error {
    case invalidURL
    case invalidResponse
    case serverError(Int)
    case decodingError(Error)
}

/// Read-only IntroDB client. Only the segment lookup the player needs is
/// implemented.
nonisolated struct IntroDBClient {
    static let shared = IntroDBClient()

    private let baseURL = "https://api.introdb.app"
    private let session: URLSession
    private let key: String?

    init(
        session: URLSession = .shared,
        key: String? = IntroDBClient.keyFromBundle()
    ) {
        self.session = session
        self.key = key
    }

    static func keyFromBundle() -> String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "IntroDBAPIKey") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Guard against an unsubstituted Info.plist variable (no .env present).
        guard let trimmed, !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    /// Fetches the known segments for a TV episode, identified by the *series'*
    /// IMDb id and the season / episode numbers. Returns `nil` when IntroDB has
    /// no usable data for the episode (the common case) so callers can quietly
    /// drop the skip affordance rather than treat it as an error. IntroDB only
    /// indexes episodic TV, so this is never called for movies or live streams.
    func segments(imdbId: String, season: Int, episode: Int) async throws -> IntroSegments? {
        let trimmed = imdbId.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents(string: baseURL + "/segments")
        components?.queryItems = [
            URLQueryItem(name: "imdb_id", value: trimmed),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode))
        ]
        guard let url = components?.url else { throw IntroDBError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let key { request.setValue(key, forHTTPHeaderField: "X-API-Key") }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw IntroDBError.invalidResponse
        }
        // 400 (invalid params for a non-episodic id) and 404 both mean "nothing
        // to skip" — surface them as a clean miss, not an error.
        if http.statusCode == 400 || http.statusCode == 404 { return nil }
        guard (200 ... 299).contains(http.statusCode) else {
            throw IntroDBError.serverError(http.statusCode)
        }

        let decoded: SegmentsResponse
        do {
            decoded = try JSONDecoder().decode(SegmentsResponse.self, from: data)
        } catch {
            throw IntroDBError.decodingError(error)
        }

        let segments = decoded.asSegments
        return segments.isEmpty ? nil : segments
    }
}

// MARK: - Domain model

/// Intro / recap / outro timestamps for one episode, in seconds from the start.
/// Only the openers (`intro`, `recap`) drive the in-player skip button today;
/// `outro` is decoded for completeness but the end-of-episode affordance is
/// owned by `PlayerNextUpOverlay`.
nonisolated struct IntroSegments: Equatable {
    struct Segment: Equatable {
        let start: TimeInterval
        let end: TimeInterval

        var duration: TimeInterval {
            max(0, end - start)
        }
    }

    var intro: Segment?
    var recap: Segment?
    var outro: Segment?

    var isEmpty: Bool {
        intro == nil && recap == nil && outro == nil
    }
}

// MARK: - Wire format

/// The subset of the `/segments` response we decode. Unknown fields
/// (`confidence`, `submission_count`, timestamps, …) are ignored.
private nonisolated struct SegmentsResponse: Decodable {
    let intro: SegmentDTO?
    let recap: SegmentDTO?
    let outro: SegmentDTO?

    var asSegments: IntroSegments {
        IntroSegments(intro: intro?.model, recap: recap?.model, outro: outro?.model)
    }
}

/// One `{ "start_sec": …, "end_sec": … }` segment. IntroDB returns fractional
/// seconds (e.g. `314.5`), so both are decoded as `Double`.
private nonisolated struct SegmentDTO: Decodable {
    let startSec: Double
    let endSec: Double

    enum CodingKeys: String, CodingKey {
        case startSec = "start_sec"
        case endSec = "end_sec"
    }

    /// `nil` for a degenerate window (end at or before start), which would never
    /// be a useful skip target.
    var model: IntroSegments.Segment? {
        guard endSec > startSec else { return nil }
        return IntroSegments.Segment(start: startSec, end: endSec)
    }
}

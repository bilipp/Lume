//
//  LumeCloudVectorExportTests+Identity.swift
//  LumeTests
//
//  identity.json: provider input → catalog row id. Synced user state addresses
//  catalog rows only by these ids, so a client deriving a different id loses
//  that state silently.
//

import Foundation
@testable import Lume
import LumeCloudKit
import Testing

extension LumeCloudVectorExportTests {
    struct IdentityDocument: Encodable {
        var format = "lume-cloud-identity-vectors"
        var notes: [String]
        var playlistId: String
        var defaultProfileId: String
        var hashes: [HashVector]
        var stalkerStreamIds: [StreamIdVector]
        var plexStreamIds: [StreamIdVector]
        var categories: [CategoryVector]
        var items: [ItemVector]
    }

    /// 64-bit values are decimal strings: they exceed JSON's exact-integer range.
    struct HashVector: Encodable {
        var input: String
        var inputUTF8Hex: String
        var hash64: String
        var key: String
        var numericId: String
        var mediaServerHash: String
    }

    struct StreamIdVector: Encodable {
        var input: String
        var streamId: String
    }

    struct CategoryVector: Encodable {
        var source: String
        var kind: String
        var apiId: String
        var id: String
    }

    struct ItemVector: Encodable {
        var source: String
        var kind: String
        var input: [String: String]
        var id: String
    }

    static func identityDocument() throws -> IdentityDocument {
        try IdentityDocument(
            notes: [
                "Every id starts with playlistId: the playlist UUID, uppercase with dashes.",
                "hash64 is FNV-1a 64 over the raw UTF-8 bytes (no trimming, case folding or normalisation); inputUTF8Hex shows those bytes.",
                "key is hash64 in unsigned base 36, lowercase. numericId is hash64 with the top bit cleared; mediaServerHash is the same function.",
                "64-bit values are decimal strings because they exceed the exact-integer range of a JSON number.",
                "stalkerStreamIds: a positive integer string is its own id, anything else is numericId(input). plexStreamIds: any integer string (no sign check), else mediaServerHash(input).",
                "Movie categories use the kind vod while movie items use movie.",
                "M3U categories use the raw group title, untrimmed; an entry without one lands in Uncategorized.",
                "Media servers (jellyfin, emby, silo) and plex share one id namespace for movies and series."
            ],
            playlistId: playlistID.uuidString,
            defaultProfileId: UserProfile.defaultProfileID.uuidString,
            hashes: hashVectors,
            stalkerStreamIds: stalkerStreamIdVectors,
            plexStreamIds: plexStreamIdVectors,
            categories: categoryVectors,
            items: itemVectors()
        )
    }

    // MARK: Hashes

    private static var hashVectors: [HashVector] {
        let inputs = [
            "",
            "http://provider.example:8080/live/viewer/secret/1001.ts",
            "http://provider.example:8080/movie/viewer/secret/2002.mkv",
            "http://provider.example/series/viewer/secret/3003.mp4?token=abc&x=1",
            "Meadow Stories",
            "meadow stories",
            " Meadow Stories ",
            "Zo\u{00EB} Harbor",
            "Zoe\u{0301} Harbor",
            "\u{00A0}Harbor\u{00A0}",
            "line\tbreak\n",
            "海辺の物語",
            "قناة الواحة",
            "📺 Lume"
        ]
        return inputs.map { input in
            HashVector(
                input: input,
                inputUTF8Hex: input.utf8.map { String(format: "%02x", $0) }.joined(),
                hash64: String(M3UIdentity.hash64(input)),
                key: M3UIdentity.key(for: input),
                numericId: String(M3UIdentity.numericId(for: input)),
                mediaServerHash: String(ContentSyncManager.mediaServerHash(input))
            )
        }
    }

    private static var stalkerStreamIdVectors: [StreamIdVector] {
        ["123", "1", "0", "-5", "007", "+12", "12.0", " 12", "abc-77", "9223372036854775807", "9223372036854775808"]
            .map { StreamIdVector(input: $0, streamId: String(ContentSyncManager.streamId(for: $0))) }
    }

    private static var plexStreamIdVectors: [StreamIdVector] {
        ["52814", "0", "-7", "+3", "007", "abc", "12.5"]
            .map { StreamIdVector(input: $0, streamId: String(ContentSyncManager.plexStreamId($0))) }
    }

    // MARK: Categories

    private static var categoryVectors: [CategoryVector] {
        let xtream: [(CategoryType, String)] = [(.live, "5"), (.vod, "12"), (.series, "30"), (.vod, "5.0")]
        let m3u: [(CategoryType, String)] = [(.live, "News"), (.vod, "News"), (.live, " Harbor Sports "), (.live, "Uncategorized")]
        let stalker: [(CategoryType, String)] = [(.live, "7"), (.vod, "*"), (.series, "42")]
        let library = "f137a2dd21bbc1b99aa5c0f6bf02a805"
        var vectors = category(.xtream, xtream) + category(.m3u, m3u) + category(.stalker, stalker)
        vectors += category(.webdav, [(.vod, "Harbor Films"), (.series, "Harbor Films")])
        for flavor in MediaServerFlavor.allCases {
            vectors += category(flavor.sourceType, [(.vod, library), (.series, library)])
        }
        vectors += category(.plex, [(.vod, "1"), (.series, "2")])
        return vectors
    }

    private static func category(_ source: PlaylistSourceType, _ entries: [(CategoryType, String)]) -> [CategoryVector] {
        entries.map { type, apiId in
            CategoryVector(
                source: source.rawValue,
                kind: type.rawValue,
                apiId: apiId,
                id: "\(playlistID.uuidString)-\(type.rawValue)-\(apiId)"
            )
        }
    }

    // MARK: Items

    private static func itemVectors() throws -> [ItemVector] {
        try xtreamItems + m3uItems + stalkerItems + mediaServerItems() + plexItems
    }

    private static func element(_ endpoint: XtreamDigestStore.Endpoint, _ id: some CustomStringConvertible) -> String {
        "\(playlistID.uuidString)-\(endpoint.idInfix)-\(id)"
    }

    private static var xtreamItems: [ItemVector] {
        let source = PlaylistSourceType.xtream.rawValue
        let series = element(.series, 30)
        return [
            ItemVector(source: source, kind: "movie", input: ["stream_id": "1001"], id: element(.movies, 1001)),
            ItemVector(source: source, kind: "series", input: ["series_id": "30"], id: series),
            ItemVector(source: source, kind: "live", input: ["stream_id": "5005"], id: element(.live, 5005)),
            ItemVector(
                source: source,
                kind: "episode",
                input: ["series_id": "30", "episode.id": "88001"],
                id: "\(series)-episode-88001"
            )
        ]
    }

    private static var m3uItems: [ItemVector] {
        let source = PlaylistSourceType.m3u.rawValue
        let movieURL = "http://provider.example:8080/movie/viewer/secret/2002.mkv"
        let liveURL = "http://provider.example:8080/live/viewer/secret/1001.ts"
        let episodeURL = "http://provider.example:8080/series/viewer/secret/3003.mp4"
        let series = M3UIdentity.seriesId(playlistId: playlistID, name: "Meadow Stories")
        return [
            ItemVector(source: source, kind: "movie", input: ["url": movieURL], id: element(.movies, M3UIdentity.key(for: movieURL))),
            ItemVector(source: source, kind: "live", input: ["url": liveURL], id: element(.live, M3UIdentity.key(for: liveURL))),
            ItemVector(source: source, kind: "series", input: ["seriesName": "Meadow Stories"], id: series),
            ItemVector(
                source: source,
                kind: "episode",
                input: ["seriesName": "Meadow Stories", "url": episodeURL],
                id: M3UIdentity.episodeId(seriesId: series, url: episodeURL)
            )
        ]
    }

    private static var stalkerItems: [ItemVector] {
        let source = PlaylistSourceType.stalker.rawValue
        let series = element(.series, ContentSyncManager.streamId(for: "42"))
        return [
            ItemVector(source: source, kind: "movie", input: ["id": "123"], id: element(.movies, ContentSyncManager.streamId(for: "123"))),
            ItemVector(source: source, kind: "movie", input: ["id": "abc-77"], id: element(.movies, ContentSyncManager.streamId(for: "abc-77"))),
            ItemVector(source: source, kind: "series", input: ["id": "42"], id: series),
            ItemVector(source: source, kind: "live", input: ["id": "9001"], id: element(.live, ContentSyncManager.streamId(for: "9001"))),
            ItemVector(
                source: source,
                kind: "episode",
                input: ["seriesId": "42", "item.id": "501", "episodeNum": "3"],
                id: "\(series)-episode-501-3"
            ),
            ItemVector(
                source: source,
                kind: "episode",
                input: ["seriesId": "42", "index": "0", "episodeNum": "1"],
                id: "\(series)-episode-0-1"
            )
        ]
    }

    private static func mediaServerItems() throws -> [ItemVector] {
        let server = try #require(URL(string: "http://media.example:8096"))
        var items: [ItemVector] = []
        for flavor in MediaServerFlavor.allCases {
            let source = flavor.sourceType.rawValue
            let prefix = "\(playlistID.uuidString)-\(flavor.idInfix)-"
            let episodeItem = try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"e5c0ffee000000000000000000000003"}"#.utf8))
            let episode = ContentSyncManager.parsedMediaServerEpisode(
                episodeItem,
                idPrefix: prefix,
                seriesItemId: "5e0000000000000000000000000000b2",
                server: server,
                token: "fictional-token"
            )
            items += [
                ItemVector(source: source, kind: "movie", input: ["Id": "a1000000000000000000000000000001"], id: prefix + "a1000000000000000000000000000001"),
                ItemVector(source: source, kind: "series", input: ["Id": "5e0000000000000000000000000000b2"], id: prefix + "5e0000000000000000000000000000b2"),
                ItemVector(source: source, kind: "episode", input: ["Id": episodeItem.id], id: episode.id),
                ItemVector(
                    source: source,
                    kind: "series",
                    input: ["SeriesName": "Meadow Stories", "note": "episode whose series is not in the library"],
                    id: prefix + "name-\(ContentSyncManager.mediaServerHash("Meadow Stories"))"
                )
            ]
        }
        return items
    }

    private static var plexItems: [ItemVector] {
        let source = PlaylistSourceType.plex.rawValue
        let prefix = "\(playlistID.uuidString)-plex-"
        return [
            ItemVector(source: source, kind: "movie", input: ["ratingKey": "52814"], id: prefix + "52814"),
            ItemVector(source: source, kind: "series", input: ["ratingKey": "61000"], id: prefix + "61000"),
            ItemVector(source: source, kind: "episode", input: ["ratingKey": "61007"], id: prefix + "episode-61007"),
            ItemVector(
                source: source,
                kind: "series",
                input: ["grandparentRatingKey": "61000", "ratingKey": "61007", "note": "series row of an episode"],
                id: prefix + "61000"
            )
        ]
    }
}

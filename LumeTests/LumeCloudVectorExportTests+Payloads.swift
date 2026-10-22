//
//  LumeCloudVectorExportTests+Payloads.swift
//  LumeTests
//
//  payloads/<type>.json: canonical encoded records from `LumeCloudPayloadCodec`,
//  one file per collection (PROTOCOL.md §3).
//

import CryptoKit
import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData

extension LumeCloudVectorExportTests {
    struct PayloadDocument: Encodable {
        var format = "lume-cloud-payload-vectors"
        var type: String
        var notes: [String]
        var rootKey: String
        var records: [PayloadRecord]
    }

    struct PayloadRecord: Encodable {
        var name: String
        var logicalKey: String
        var rid: String
        /// The last-synced bytes the record was re-encoded over, when the case
        /// is about carrying unknown data forward.
        var previousCanonicalPayload: String?
        var payload: JSONValue
        var canonicalPayload: String
    }

    private static let payloadNotes = [
        "canonicalPayload is normative: the exact RFC 8785 plaintext the codec produces for the model. payload is the same value, pretty-printed for reading.",
        "rid = base64url(HMAC-SHA256(idKey, UTF8(logicalKey))) with the keys derived from rootKey, the root key of crypto.json.",
        "Dates are epoch milliseconds, UUIDs uppercase. A nil profile in a logical key is the literal none.",
        "previousCanonicalPayload: the last-synced bytes of the same record.",
        "Data fields and top-level members this build doesn't know carry over from previousCanonicalPayload unchanged; known fields (here updatedAt) take the model's value."
    ]

    /// Encodes models of one collection into a document, cases in order.
    private struct PayloadCollector {
        let keys: LumeCloudKeys
        var records: [PayloadRecord] = []

        mutating func add(_ name: String, _ model: some LumeCloudPayloadMappable, previous: LumeCloudPayload? = nil) throws {
            let previousBytes = try previous?.encoded()
            let bytes = try LumeCloudPayloadCodec.encoded(model, previous: previousBytes)
            try records.append(PayloadRecord(
                name: name,
                logicalKey: model.lumeCloudKey,
                rid: keys.recordID(for: model.lumeCloudKey),
                previousCanonicalPayload: previousBytes.map { String(bytes: $0, encoding: .utf8) ?? "" },
                payload: LumeCloudVectorFiles.json(bytes),
                canonicalPayload: String(bytes: bytes, encoding: .utf8) ?? ""
            ))
        }
    }

    /// The record as a newer client last wrote it: an older `updatedAt`, plus
    /// one data field and one top-level member this build doesn't know.
    private static func withUnknownData(_ model: some LumeCloudPayloadMappable) -> LumeCloudPayload {
        var payload = LumeCloudPayloadCodec.payload(for: model, previous: nil)
        payload.data["updatedAt"] = 1_759_000_000_000
        payload.data["futureField"] = ["nested": ["é", "a/b", 0.00001, 1e21]]
        payload.extra["futureMeta"] = "kept"
        return payload
    }

    // swiftlint:disable:next function_body_length
    static func payloadDocuments(in context: ModelContext) throws -> [PayloadDocument] {
        let keys = try LumeCloudKeys(rootKey: rootKey)
        func collect(_ build: (inout PayloadCollector) throws -> Void) throws -> [PayloadRecord] {
            var collector = PayloadCollector(keys: keys)
            try build(&collector)
            return collector.records
        }
        func inserted<Model: PersistentModel>(_ model: Model) -> Model {
            context.insert(model)
            return model
        }
        let edited = date(1_760_000_123_456)
        let created = date(1_760_000_000_000)
        let playlistID = playlistID
        let profileID = profileID

        let playlists = try collect { records in
            let playlist = inserted(SyncedPlaylist(
                id: playlistID, name: "Harbor Lights", serverURL: "http://provider.example:8080", username: "viewer",
                password: "secret", sourceTypeRaw: PlaylistSourceType.xtream.rawValue,
                epgURL: "http://provider.example:8080/xmltv.php", syncEnabled: true, hiddenTabsRaw: "series,liveTV",
                updatedAt: edited
            ))
            try records.add("xtream playlist", playlist)
            let stalker = inserted(SyncedPlaylist(
                id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000AB02")!, name: "Zoë's \"Portal\"",
                serverURL: "http://portal.example/c/", username: "", password: "", macAddress: "00:1A:79:00:00:01",
                sourceTypeRaw: PlaylistSourceType.stalker.rawValue, epgURL: nil, syncEnabled: false, updatedAt: edited
            ))
            try records.add("stalker playlist without an EPG URL", stalker)
            try records.add("unknown data survives a re-encode", playlist, previous: withUnknownData(playlist))
        }

        let contents = try collect { records in
            let movie = inserted(UserContentState(
                contentId: "\(playlistID.uuidString)-movie-1001", kind: .movie, profileID: profileID,
                watchProgress: 1234.5, isWatched: false, lastWatchedDate: edited, isFavorite: true,
                favoriteOrder: 3, recommendationVoteRaw: -1, updatedAt: edited
            ))
            try records.add("movie progress and favorite", movie)
            try records.add("category visibility and order", inserted(UserContentState(
                contentId: "\(playlistID.uuidString)-live-5", kind: .category, profileID: profileID,
                isHidden: true, customOrder: 2, updatedAt: edited
            )))
            try records.add("legacy record without a profile", inserted(UserContentState(
                contentId: "\(playlistID.uuidString)-live-5005", kind: .live, isFavorite: true,
                addedToWatchlistDate: created, updatedAt: edited
            )))
            try records.add("unknown data survives a re-encode", movie, previous: withUnknownData(movie))
        }

        let profiles = try collect { records in
            let child = inserted(UserProfile(
                id: profileID, name: "Zoë's \"Room\"", symbolName: "star.fill", colorRaw: ProfileColor.teal.rawValue,
                sortOrder: 1, isChild: true, createdAt: created, updatedAt: edited
            ))
            try records.add("child profile", child)
            try records.add("default profile", inserted(UserProfile(
                id: UserProfile.defaultProfileID, name: "Harbor", createdAt: created, updatedAt: created
            )))
            try records.add("unknown data survives a re-encode", child, previous: withUnknownData(child))
        }

        let guides = try collect { records in
            let guide = inserted(SyncedEPGSource(
                id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000EE01")!, name: "Meadow Guide",
                url: "https://guide.example/xmltv.xml.gz", isEnabled: false, updatedAt: edited
            ))
            try records.add("manual EPG source", guide)
            try records.add("unknown data survives a re-encode", guide, previous: withUnknownData(guide))
        }

        let pins = try collect { records in
            let hash = SHA256.hash(data: Data(("lume.parental.v1" + "1234").utf8)).map { String(format: "%02x", $0) }.joined()
            let pin = inserted(SyncedParentalPIN(pinHash: hash, updatedAt: edited))
            try records.add("PIN 1234", pin)
            try records.add("unknown data survives a re-encode", pin, previous: withUnknownData(pin))
        }

        let restrictions = try collect { records in
            let restriction = inserted(SyncedCategoryRestriction(categoryID: "\(playlistID.uuidString)-vod-12", updatedAt: edited))
            try records.add("restricted movie category", restriction)
            try records.add("unknown data survives a re-encode", restriction, previous: withUnknownData(restriction))
        }

        let follows = try collect { records in
            let team = inserted(SyncedSportsFollow(
                key: "demo:soccer/meadow.1:4021", kindRaw: "team", profileID: profileID, sortOrder: 4, updatedAt: edited
            ))
            try records.add("followed team", team)
            try records.add("league without a profile", inserted(SyncedSportsFollow(
                key: "demo:soccer/meadow.1", kindRaw: "league", profileID: nil, sortOrder: 0, updatedAt: edited
            )))
            try records.add("unknown data survives a re-encode", team, previous: withUnknownData(team))
        }

        let servers = try collect { records in
            let server = inserted(SyncedRecordingServer(
                id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000DD01")!, name: "Basement Recorder",
                baseURL: "http://recorder.example:8089", serverID: UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000DD02"),
                deviceID: UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000DD03"), token: "fictional-pairing-token",
                isEnabled: true, updatedAt: edited
            ))
            try records.add("paired recorder", server)
            try records.add("unpaired recorder", inserted(SyncedRecordingServer(
                id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000DD09")!, name: "Attic",
                baseURL: "http://attic.example", isEnabled: false, updatedAt: edited
            )))
            try records.add("unknown data survives a re-encode", server, previous: withUnknownData(server))
        }

        let preferences = try collect { records in
            let prefs = inserted(SyncedLiveTVPreferences(showsFavorites: false, showsRecentlyWatched: true, updatedAt: edited))
            try records.add("Live TV rails", prefs)
            try records.add("unknown data survives a re-encode", prefs, previous: withUnknownData(prefs))
        }

        let rootKey = Base64URL.encode(rootKey)
        let byType: [(any LumeCloudPayloadMappable.Type, [PayloadRecord])] = [
            (SyncedPlaylist.self, playlists), (UserContentState.self, contents), (UserProfile.self, profiles),
            (SyncedEPGSource.self, guides), (SyncedParentalPIN.self, pins),
            (SyncedCategoryRestriction.self, restrictions), (SyncedSportsFollow.self, follows),
            (SyncedRecordingServer.self, servers), (SyncedLiveTVPreferences.self, preferences)
        ]
        return byType.map { model, records in
            PayloadDocument(type: model.lumeCloudType, notes: payloadNotes, rootKey: rootKey, records: records)
        }
    }
}

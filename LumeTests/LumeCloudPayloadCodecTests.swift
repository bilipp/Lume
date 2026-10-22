//
//  LumeCloudPayloadCodecTests.swift
//  LumeTests
//
//  The mirror-model ↔ Lume Cloud payload mapping (PROTOCOL.md §3): every type
//  round-trips, dates are epoch milliseconds so sub-millisecond noise never
//  marks a record dirty, and fields this build doesn't know survive a
//  re-encode. Models live in an in-memory Lume Cloud container
//  (`cloudKitDatabase: .none`).
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Testing

@MainActor
struct LumeCloudPayloadCodecTests {
    private typealias Codec = LumeCloudPayloadCodec

    private let container: ModelContainer
    private let profileID = UUID(uuidString: "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
    private let edited = Date(timeIntervalSince1970: 1_760_000_123.456)

    init() throws {
        container = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
    }

    private func inserted<Model: PersistentModel>(_ model: Model) -> Model {
        container.mainContext.insert(model)
        return model
    }

    private func string(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? ""
    }

    private func roundTrip<Model: LumeCloudPayloadMappable>(_ model: Model) throws -> (Model, Data) {
        let bytes = try Codec.encoded(model, previous: nil)
        let decoded = try Codec.makeModel(from: LumeCloudPayload.decode(bytes), as: Model.self)
        #expect(try Codec.encoded(decoded, previous: nil) == bytes)
        return (decoded, bytes)
    }

    // MARK: Round trips

    @Test func `a playlist round-trips`() throws {
        let id = try #require(UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000AB01"))
        let playlist = inserted(SyncedPlaylist(
            id: id,
            name: "Harbor Lights",
            serverURL: "http://provider.example:8080",
            username: "viewer",
            password: "hunter2",
            macAddress: "00:1A:79:00:00:01",
            sourceTypeRaw: PlaylistSourceType.stalker.rawValue,
            epgURL: nil,
            syncEnabled: false,
            hiddenTabsRaw: "series,liveTV",
            updatedAt: edited
        ))

        let (decoded, bytes) = try roundTrip(playlist)
        let payload = try LumeCloudPayload.decode(bytes)
        #expect(payload.type == "playlist")
        #expect(payload.key == "playlist/0A1B2C3D-0000-4000-8000-00000000AB01")
        #expect(payload.data["epgURL"] == .null)
        #expect(payload.data["updatedAt"] == .number(1_760_000_123_456))

        #expect(decoded.id == id)
        #expect(decoded.name == "Harbor Lights")
        #expect(decoded.password == "hunter2")
        #expect(decoded.macAddress == "00:1A:79:00:00:01")
        #expect(decoded.sourceTypeRaw == PlaylistSourceType.stalker.rawValue)
        #expect(decoded.epgURL == nil)
        #expect(!decoded.syncEnabled)
        #expect(decoded.hiddenTabsRaw == "series,liveTV")
    }

    @Test func `a content state round-trips`() throws {
        let state = inserted(UserContentState(
            contentId: "0A1B2C3D-0000-4000-8000-00000000AB01-movie-1001",
            kind: .movie,
            profileID: profileID,
            watchProgress: 1234.5,
            isWatched: true,
            lastWatchedDate: edited,
            isFavorite: true,
            addedToWatchlistDate: nil,
            favoriteOrder: 3,
            recommendationVoteRaw: -1,
            isHidden: true,
            customOrder: nil,
            updatedAt: edited
        ))

        let (decoded, bytes) = try roundTrip(state)
        let payload = try LumeCloudPayload.decode(bytes)
        #expect(payload.key == "content/6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D/0A1B2C3D-0000-4000-8000-00000000AB01-movie-1001")
        #expect(payload.data["profileID"] == .string("6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"))
        #expect(payload.data["watchProgress"] == .number(1234.5))

        #expect(decoded.profileID == profileID)
        #expect(decoded.kind == .movie)
        #expect(decoded.watchProgress == 1234.5)
        #expect(decoded.isWatched)
        #expect(decoded.isFavorite)
        #expect(decoded.addedToWatchlistDate == nil)
        #expect(decoded.favoriteOrder == 3)
        #expect(decoded.recommendationVoteRaw == -1)
        #expect(decoded.isHidden)
        #expect(decoded.customOrder == nil)
    }

    @Test func `a legacy content state without a profile keys as none`() throws {
        let state = inserted(UserContentState(contentId: "live-7", kind: .live, isFavorite: true, updatedAt: edited))
        let (decoded, bytes) = try roundTrip(state)
        let payload = try LumeCloudPayload.decode(bytes)
        #expect(payload.key == "content/none/live-7")
        #expect(payload.data["profileID"] == .null)
        #expect(decoded.profileID == nil)
    }

    @Test func `a profile round-trips`() throws {
        let profile = inserted(UserProfile(
            id: profileID,
            name: "Zoë's \"Room\"",
            symbolName: "star.fill",
            colorRaw: ProfileColor.teal.rawValue,
            sortOrder: 2,
            isChild: true,
            createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            updatedAt: edited
        ))

        let (decoded, bytes) = try roundTrip(profile)
        #expect(try LumeCloudPayload.decode(bytes).key == "profile/6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")
        #expect(decoded.id == profileID)
        #expect(decoded.name == "Zoë's \"Room\"")
        #expect(decoded.symbolName == "star.fill")
        #expect(decoded.colorRaw == ProfileColor.teal.rawValue)
        #expect(decoded.sortOrder == 2)
        #expect(decoded.isChild)
        #expect(decoded.createdAt == Date(timeIntervalSince1970: 1_760_000_000))
    }

    @Test func `an EPG source round-trips`() throws {
        let id = try #require(UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000EE01"))
        let source = inserted(SyncedEPGSource(
            id: id,
            name: "Meadow Guide",
            url: "https://guide.example/xmltv.xml.gz",
            isEnabled: false,
            updatedAt: edited
        ))

        let (decoded, bytes) = try roundTrip(source)
        #expect(try LumeCloudPayload.decode(bytes).key == "epgSource/0A1B2C3D-0000-4000-8000-00000000EE01")
        #expect(decoded.id == id)
        #expect(decoded.name == "Meadow Guide")
        #expect(decoded.url == "https://guide.example/xmltv.xml.gz")
        #expect(!decoded.isEnabled)
    }

    @Test func `a parental PIN round-trips`() throws {
        let hash = String(repeating: "0123456789abcdef", count: 4)
        let pin = inserted(SyncedParentalPIN(pinHash: hash, updatedAt: edited))

        let (decoded, bytes) = try roundTrip(pin)
        let payload = try LumeCloudPayload.decode(bytes)
        #expect(payload.type == "parentalPin")
        #expect(payload.key == "parentalPin")
        #expect(payload.data == ["pinHash": .string(hash), "updatedAt": .number(1_760_000_123_456)])
        #expect(decoded.id == SyncedParentalPIN.singletonID)
        #expect(decoded.pinHash == hash)
        #expect(decoded.updatedAt == Date(timeIntervalSince1970: 1_760_000_123.456))
    }

    @Test func `a category restriction round-trips`() throws {
        let categoryID = "0A1B2C3D-0000-4000-8000-00000000AB01-live-12"
        let restriction = inserted(SyncedCategoryRestriction(categoryID: categoryID, updatedAt: edited))

        let (decoded, bytes) = try roundTrip(restriction)
        let payload = try LumeCloudPayload.decode(bytes)
        #expect(payload.type == "categoryRestriction")
        #expect(payload.key == "categoryRestriction/\(categoryID)")
        #expect(payload.data["isRestricted"] == true)
        #expect(decoded.categoryID == categoryID)
        #expect(decoded.isRestricted)
    }

    @Test func `a sports follow round-trips`() throws {
        let follow = inserted(SyncedSportsFollow(
            key: "espn:soccer/xyz.1:4021",
            kindRaw: "team",
            profileID: profileID,
            sortOrder: 4,
            updatedAt: edited
        ))

        let (decoded, bytes) = try roundTrip(follow)
        let payload = try LumeCloudPayload.decode(bytes)
        #expect(payload.type == "sportsFollow")
        #expect(payload.key == "sportsFollow/6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D/espn:soccer/xyz.1:4021")
        #expect(payload.data["profileID"] == .string("6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"))
        #expect(payload.data["sortOrder"] == 4)
        #expect(decoded.key == "espn:soccer/xyz.1:4021")
        #expect(decoded.kindRaw == "team")
        #expect(decoded.profileID == profileID)
        #expect(decoded.sortOrder == 4)
    }

    @Test func `a sports follow without a profile keys as none`() throws {
        let follow = inserted(SyncedSportsFollow(key: "espn:soccer/xyz.1", kindRaw: "league", profileID: nil))
        let (decoded, bytes) = try roundTrip(follow)
        let payload = try LumeCloudPayload.decode(bytes)
        #expect(payload.key == "sportsFollow/none/espn:soccer/xyz.1")
        #expect(payload.data["profileID"] == .null)
        #expect(decoded.profileID == nil)
        #expect(decoded.kindRaw == "league")
    }

    @Test func `a recording server round-trips with its token`() throws {
        let id = try #require(UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000DD01"))
        let serverID = try #require(UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000DD02"))
        let server = inserted(SyncedRecordingServer(
            id: id,
            name: "Basement Recorder",
            baseURL: "http://recorder.example:8089",
            serverID: serverID,
            deviceID: nil,
            token: "fictional-pairing-token",
            isEnabled: false,
            updatedAt: edited
        ))

        let (decoded, bytes) = try roundTrip(server)
        let payload = try LumeCloudPayload.decode(bytes)
        #expect(payload.type == "recordingServer")
        #expect(payload.key == "recordingServer/0A1B2C3D-0000-4000-8000-00000000DD01")
        #expect(payload.data["serverID"] == .string("0A1B2C3D-0000-4000-8000-00000000DD02"))
        #expect(payload.data["deviceID"] == .null)
        #expect(decoded.id == id)
        #expect(decoded.kind == .lumeRecorder)
        #expect(decoded.name == "Basement Recorder")
        #expect(decoded.baseURL == "http://recorder.example:8089")
        #expect(decoded.serverID == serverID)
        #expect(decoded.deviceID == nil)
        #expect(decoded.token == "fictional-pairing-token")
        #expect(!decoded.isEnabled)
    }

    @Test func `an unknown recording server kind is kept verbatim`() throws {
        let server = inserted(SyncedRecordingServer(name: "Attic", baseURL: "http://attic.example"))
        var payload = Codec.payload(for: server, previous: nil)
        payload.data["kindRaw"] = "futureRecorder"
        let decoded = try Codec.makeModel(from: payload, as: SyncedRecordingServer.self)
        #expect(decoded.kind == nil)
        #expect(Codec.payload(for: decoded, previous: nil).data["kindRaw"] == "futureRecorder")
    }

    @Test func `the Live TV preferences round-trip`() throws {
        let preferences = inserted(SyncedLiveTVPreferences(
            showsFavorites: false,
            showsRecentlyWatched: true,
            updatedAt: edited
        ))

        let (decoded, bytes) = try roundTrip(preferences)
        let payload = try LumeCloudPayload.decode(bytes)
        #expect(payload.type == "liveTVPrefs")
        #expect(payload.key == "liveTVPrefs")
        #expect(payload.data == [
            "showsFavorites": false,
            "showsRecentlyWatched": true,
            "updatedAt": .number(1_760_000_123_456)
        ])
        #expect(decoded.id == SyncedLiveTVPreferences.singletonID)
        #expect(!decoded.showsFavorites)
        #expect(decoded.showsRecentlyWatched)
    }

    @Test func `UUIDs are written uppercase`() throws {
        let id = try #require(UUID(uuidString: "abcdef01-2345-4678-9abc-def012345678"))
        let source = inserted(SyncedEPGSource(id: id, name: "Guide", url: "https://guide.example", isEnabled: true))
        let payload = Codec.payload(for: source, previous: nil)
        #expect(payload.key == "epgSource/ABCDEF01-2345-4678-9ABC-DEF012345678")
        #expect(payload.data["id"] == .string("ABCDEF01-2345-4678-9ABC-DEF012345678"))
    }

    // MARK: Dirty detection

    @Test func `a sub-millisecond date difference is not dirty`() throws {
        let base = Date(timeIntervalSince1970: 1_760_000_123.4562)
        let first = inserted(UserProfile(id: profileID, name: "Juniper", createdAt: base, updatedAt: base))
        let second = inserted(UserProfile(
            id: profileID,
            name: "Juniper",
            createdAt: base.addingTimeInterval(0.0002),
            updatedAt: base.addingTimeInterval(0.0002)
        ))
        #expect(try Codec.encoded(first, previous: nil) == Codec.encoded(second, previous: nil))
    }

    @Test func `a pulled date re-encodes to the same millisecond`() throws {
        let synced = try Codec.encoded(inserted(UserProfile(id: profileID, name: "Juniper", updatedAt: edited)), previous: nil)
        let pulled = try inserted(Codec.makeModel(from: LumeCloudPayload.decode(synced), as: UserProfile.self))
        #expect(try Codec.encoded(pulled, previous: synced) == synced)

        let existing = inserted(UserProfile(id: profileID, name: "Marigold"))
        try Codec.apply(LumeCloudPayload.decode(synced), to: existing)
        #expect(try Codec.encoded(existing, previous: synced) == synced)
    }

    @Test func `the protocol vector re-encodes byte for byte`() throws {
        // `records[1].canonicalPayload` of ../LumeCloud/spec/vectors/crypto.json.
        let vector = [
            #"{"data":{"addedToWatchlistDate":null,"contentId":"movie-1001","customOrder":null,"favoriteOrder":3"#,
            #","futureField":{"nested":["é","a/b","line\nbreak\u0001",0.00001,1e-7,1e+21]}"#,
            #","isFavorite":true,"isHidden":false,"isWatched":false,"kindRaw":"movie","lastWatchedDate":1760000200000"#,
            #","profileID":"6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D","recommendationVoteRaw":-1,"updatedAt":1760000200000,"watchProgress":1234.5}"#,
            #","key":"content/6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D/movie-1001","type":"content","v":1}"#
        ].joined()
        let bytes = Data(vector.utf8)
        let state = try Codec.makeModel(from: LumeCloudPayload.decode(bytes), as: UserContentState.self)
        #expect(state.favoriteOrder == 3)
        #expect(state.recommendationVoteRaw == -1)
        #expect(try string(Codec.encoded(state, previous: bytes)) == vector)
    }

    @Test func `a sub-millisecond date difference is not dirty for the part-2 types`() throws {
        let base = Date(timeIntervalSince1970: 1_760_000_123.4562)
        let later = base.addingTimeInterval(0.0002)
        let pairs: [(any LumeCloudPayloadMappable, any LumeCloudPayloadMappable)] = [
            (SyncedParentalPIN(pinHash: "ab", updatedAt: base), SyncedParentalPIN(pinHash: "ab", updatedAt: later)),
            (
                SyncedCategoryRestriction(categoryID: "c-1", updatedAt: base),
                SyncedCategoryRestriction(categoryID: "c-1", updatedAt: later)
            ),
            (
                SyncedSportsFollow(key: "espn:x", profileID: profileID, updatedAt: base),
                SyncedSportsFollow(key: "espn:x", profileID: profileID, updatedAt: later)
            ),
            (
                SyncedRecordingServer(id: profileID, name: "R", baseURL: "http://r.example", updatedAt: base),
                SyncedRecordingServer(id: profileID, name: "R", baseURL: "http://r.example", updatedAt: later)
            ),
            (
                SyncedLiveTVPreferences(showsFavorites: true, showsRecentlyWatched: false, updatedAt: base),
                SyncedLiveTVPreferences(showsFavorites: true, showsRecentlyWatched: false, updatedAt: later)
            )
        ]
        for (first, second) in pairs {
            container.mainContext.insert(first)
            container.mainContext.insert(second)
            #expect(try Codec.encoded(first, previous: nil) == Codec.encoded(second, previous: nil))
        }
    }

    // MARK: Unknown data

    @Test func `unknown data fields and extra survive a re-encode`() throws {
        let profile = inserted(UserProfile(id: profileID, name: "Juniper", updatedAt: edited))
        var previous = Codec.payload(for: profile, previous: nil)
        previous.data["futureField"] = ["nested": [1, "two"]]
        previous.data["name"] = "Stale name"
        previous.extra["futureTopLevel"] = true
        let previousBytes = try previous.encoded()

        profile.name = "Marigold"
        let payload = try LumeCloudPayload.decode(Codec.encoded(profile, previous: previousBytes))
        #expect(payload.data["futureField"] == ["nested": [1, "two"]])
        #expect(payload.extra["futureTopLevel"] == true)
        #expect(payload.data["name"] == "Marigold")
    }

    @Test func `unknown fields survive a re-encode of the part-2 types`() throws {
        let models: [any LumeCloudPayloadMappable] = [
            SyncedParentalPIN(pinHash: "ab", updatedAt: edited),
            SyncedCategoryRestriction(categoryID: "c-1", updatedAt: edited),
            SyncedSportsFollow(key: "espn:x", profileID: profileID, updatedAt: edited),
            SyncedRecordingServer(name: "R", baseURL: "http://r.example", token: "t", updatedAt: edited),
            SyncedLiveTVPreferences(showsFavorites: true, showsRecentlyWatched: true, updatedAt: edited)
        ]
        for model in models {
            container.mainContext.insert(model)
            var previous = Codec.payload(for: model, previous: nil)
            previous.data["futureField"] = ["nested": [1, "two"]]
            previous.extra["futureTopLevel"] = true
            let previousBytes = try previous.encoded()

            let payload = try LumeCloudPayload.decode(Codec.encoded(model, previous: previousBytes))
            #expect(payload.data["futureField"] == ["nested": [1, "two"]])
            #expect(payload.extra["futureTopLevel"] == true)
            #expect(try Codec.encoded(model, previous: previousBytes) == previousBytes)
        }
    }

    @Test func `unknown fields of another record are not carried over`() throws {
        let other = inserted(UserProfile(name: "Juniper"))
        var previous = Codec.payload(for: other, previous: nil)
        previous.data["futureField"] = 1
        let profile = inserted(UserProfile(id: profileID, name: "Marigold"))
        let payload = try LumeCloudPayload.decode(Codec.encoded(profile, previous: previous.encoded()))
        #expect(payload.data["futureField"] == nil)
    }

    @Test func `an unknown content kind is kept verbatim`() throws {
        let state = inserted(UserContentState(contentId: "clip-9", kind: .movie, profileID: profileID, updatedAt: edited))
        var payload = Codec.payload(for: state, previous: nil)
        payload.data["kindRaw"] = "clip"
        let decoded = try Codec.makeModel(from: payload, as: UserContentState.self)
        #expect(Codec.payload(for: decoded, previous: nil).data["kindRaw"] == "clip")
    }

    // MARK: Rejection

    @Test func `a payload of another type is rejected`() throws {
        let payload = Codec.payload(for: inserted(UserProfile(id: profileID, name: "Juniper")), previous: nil)
        #expect(throws: Codec.CodecError.wrongType) {
            try Codec.makeModel(from: payload, as: SyncedEPGSource.self)
        }
    }

    @Test func `a key that disagrees with the data is rejected`() throws {
        var payload = Codec.payload(for: inserted(UserProfile(id: profileID, name: "Juniper")), previous: nil)
        payload.key = Codec.profileKey(id: UUID())
        #expect(throws: Codec.CodecError.keyMismatch) {
            try Codec.makeModel(from: payload, as: UserProfile.self)
        }
    }

    @Test func `a payload of another record never touches the model`() throws {
        let target = inserted(UserProfile(name: "Juniper"))
        let payload = Codec.payload(for: inserted(UserProfile(id: profileID, name: "Marigold")), previous: nil)
        #expect(throws: Codec.CodecError.keyMismatch) {
            try Codec.apply(payload, to: target)
        }
        #expect(target.name == "Juniper")
    }

    @Test func `a malformed field leaves the model untouched`() throws {
        let profile = inserted(UserProfile(id: profileID, name: "Juniper", sortOrder: 1, updatedAt: edited))
        var payload = Codec.payload(for: profile, previous: nil)
        payload.data["name"] = "Marigold"
        payload.data["sortOrder"] = 1.5
        #expect(throws: Codec.CodecError.invalidField("sortOrder")) {
            try Codec.apply(payload, to: profile)
        }
        payload.data["sortOrder"] = nil
        #expect(throws: Codec.CodecError.missingField("sortOrder")) {
            try Codec.apply(payload, to: profile)
        }
        #expect(profile.name == "Juniper")
        #expect(profile.sortOrder == 1)
    }

    @Test func `a newer payload schema version is rejected`() throws {
        var payload = Codec.payload(for: inserted(UserProfile(id: profileID, name: "Juniper")), previous: nil)
        payload.v = LumeCloudPayload.currentVersion + 1
        #expect(throws: Codec.CodecError.unsupportedVersion) {
            try Codec.makeModel(from: payload, as: UserProfile.self)
        }
    }
}

// MARK: - Logical keys

extension LumeCloudPayloadCodecTests {
    @Test func `every canonical logical key parses and renders back`() throws {
        let id = "0A1B2C3D-0000-4000-8000-00000000AB01"
        let uuid = try #require(UUID(uuidString: id))
        let profile = "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
        let cases: [(String, LumeCloudLogicalKey, String)] = [
            ("playlist/\(id)", .playlist(id: uuid), "playlist"),
            ("content/\(profile)/\(id)-movie-1", .content(profileID: profileID, contentId: "\(id)-movie-1"), "content"),
            ("content/none/live-7", .content(profileID: nil, contentId: "live-7"), "content"),
            ("content/none/a/b", .content(profileID: nil, contentId: "a/b"), "content"),
            ("profile/\(id)", .profile(id: uuid), "profile"),
            ("epgSource/\(id)", .epgSource(id: uuid), "epgSource"),
            ("parentalPin", .parentalPIN, "parentalPin"),
            ("categoryRestriction/\(id)-live-12", .categoryRestriction(categoryID: "\(id)-live-12"), "categoryRestriction"),
            (
                "sportsFollow/\(profile)/espn:soccer/xyz.1:4021",
                .sportsFollow(profileID: profileID, key: "espn:soccer/xyz.1:4021"),
                "sportsFollow"
            ),
            ("sportsFollow/none/espn:soccer/xyz.1", .sportsFollow(profileID: nil, key: "espn:soccer/xyz.1"), "sportsFollow"),
            ("recordingServer/\(id)", .recordingServer(id: uuid), "recordingServer"),
            ("liveTVPrefs", .liveTVPreferences, "liveTVPrefs")
        ]
        for (raw, expected, type) in cases {
            let parsed = try #require(LumeCloudLogicalKey(raw))
            #expect(parsed == expected)
            #expect(parsed.key == raw)
            #expect(parsed.type == type)
            #expect(parsed.modelType.lumeCloudType == type)
        }
    }

    @Test func `non-canonical or unknown logical keys don't parse`() {
        let rejected = [
            "",
            "playlist",
            "playlist/",
            "playlist/not-a-uuid",
            "playlist/0a1b2c3d-0000-4000-8000-00000000ab01",
            "content/none",
            "content/none/",
            "content/6f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d/movie-1",
            "content/someone/movie-1",
            "parentalPin/extra",
            "liveTVPrefs/",
            "categoryRestriction/",
            "sportsFollow/none/",
            "recordingServer/0A1B2C3D",
            "futureType/abc"
        ]
        for raw in rejected {
            #expect(LumeCloudLogicalKey(raw) == nil, "\(raw)")
        }
    }

    @Test func `the payload key of every model parses to its own type`() throws {
        let models: [any LumeCloudPayloadMappable] = [
            SyncedPlaylist(id: UUID(), name: "P", serverURL: "", username: "", password: "", sourceTypeRaw: "xtream", epgURL: nil, syncEnabled: true),
            UserContentState(contentId: "movie-1", kind: .movie, profileID: profileID),
            UserProfile(name: "Juniper"),
            SyncedEPGSource(id: UUID(), name: "G", url: "https://guide.example", isEnabled: true),
            SyncedParentalPIN(pinHash: "ab"),
            SyncedCategoryRestriction(categoryID: "c-1"),
            SyncedSportsFollow(key: "espn:x", profileID: nil),
            SyncedRecordingServer(name: "R", baseURL: "http://r.example"),
            SyncedLiveTVPreferences(showsFavorites: true, showsRecentlyWatched: true)
        ]
        #expect(models.count == Codec.mappableModels.count)
        for model in models {
            container.mainContext.insert(model)
            let parsed = try #require(LumeCloudLogicalKey(model.lumeCloudKey))
            #expect(parsed.type == type(of: model).lumeCloudType)
        }
    }

    @Test func `a payload dispatches on its type`() throws {
        let follow = inserted(SyncedSportsFollow(key: "espn:x", profileID: profileID, sortOrder: 2, updatedAt: edited))
        let decoded = try #require(try Codec.makeAnyModel(from: Codec.payload(for: follow, previous: nil)))
        let typed = try #require(decoded as? SyncedSportsFollow)
        #expect(typed.key == "espn:x")
        #expect(typed.sortOrder == 2)

        for model in Codec.mappableModels {
            #expect(Codec.modelType(forRecordType: model.lumeCloudType) == model)
        }
    }

    @Test func `an unknown record type dispatches to nothing`() throws {
        let payload = LumeCloudPayload(type: "futureType", key: "futureType/abc", data: ["a": 1])
        #expect(Codec.modelType(forRecordType: "futureType") == nil)
        #expect(try Codec.makeAnyModel(from: payload) == nil)
    }
}

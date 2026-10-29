import Foundation
import LumeCloudKit
import SwiftData

// MARK: - parentalPin

nonisolated extension SyncedParentalPIN: LumeCloudPayloadMappable {
    static var lumeCloudType: String {
        "parentalPin"
    }

    var lumeCloudKey: String {
        LumeCloudPayloadCodec.parentalPINKey
    }

    var lumeCloudFields: [String: JSONValue] {
        [
            "pinHash": .string(pinHash),
            "updatedAt": LumeCloudPayloadCodec.wire(updatedAt)
        ]
    }

    static func lumeCloudKey(for _: LumeCloudPayloadCodec.Fields) throws -> String {
        LumeCloudPayloadCodec.parentalPINKey
    }

    func applyLumeCloudFields(_ fields: LumeCloudPayloadCodec.Fields) throws {
        let pinHash = try fields.string("pinHash")
        let updatedAt = try fields.date("updatedAt")

        self.pinHash = pinHash
        self.updatedAt = updatedAt
    }

    static func makeBlankForLumeCloud() -> SyncedParentalPIN {
        SyncedParentalPIN(pinHash: "")
    }
}

// MARK: - categoryRestriction

nonisolated extension SyncedCategoryRestriction: LumeCloudPayloadMappable {
    static var lumeCloudType: String {
        "categoryRestriction"
    }

    var lumeCloudKey: String {
        LumeCloudPayloadCodec.categoryRestrictionKey(categoryID: categoryID)
    }

    var lumeCloudFields: [String: JSONValue] {
        [
            "categoryID": .string(categoryID),
            "isRestricted": .bool(isRestricted),
            "updatedAt": LumeCloudPayloadCodec.wire(updatedAt)
        ]
    }

    static func lumeCloudKey(for fields: LumeCloudPayloadCodec.Fields) throws -> String {
        try LumeCloudPayloadCodec.categoryRestrictionKey(categoryID: fields.string("categoryID"))
    }

    func applyLumeCloudFields(_ fields: LumeCloudPayloadCodec.Fields) throws {
        let categoryID = try fields.string("categoryID")
        let isRestricted = try fields.bool("isRestricted")
        let updatedAt = try fields.date("updatedAt")

        self.categoryID = categoryID
        self.isRestricted = isRestricted
        self.updatedAt = updatedAt
    }

    static func makeBlankForLumeCloud() -> SyncedCategoryRestriction {
        SyncedCategoryRestriction(categoryID: "")
    }
}

// MARK: - sportsFollow

nonisolated extension SyncedSportsFollow: LumeCloudPayloadMappable {
    static var lumeCloudType: String {
        "sportsFollow"
    }

    var lumeCloudKey: String {
        LumeCloudPayloadCodec.sportsFollowKey(profileID: profileID, key: key)
    }

    var lumeCloudFields: [String: JSONValue] {
        typealias Codec = LumeCloudPayloadCodec
        return [
            "key": .string(key),
            "kindRaw": .string(kindRaw),
            "profileID": Codec.wire(profileID),
            "sortOrder": Codec.wire(sortOrder),
            "updatedAt": Codec.wire(updatedAt)
        ]
    }

    static func lumeCloudKey(for fields: LumeCloudPayloadCodec.Fields) throws -> String {
        try LumeCloudPayloadCodec.sportsFollowKey(
            profileID: fields.optionalUUID("profileID"),
            key: fields.string("key")
        )
    }

    func applyLumeCloudFields(_ fields: LumeCloudPayloadCodec.Fields) throws {
        let key = try fields.string("key")
        let kindRaw = try fields.string("kindRaw")
        let profileID = try fields.optionalUUID("profileID")
        let sortOrder = try fields.int("sortOrder")
        let updatedAt = try fields.date("updatedAt")

        self.key = key
        self.kindRaw = kindRaw
        self.profileID = profileID
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }

    static func makeBlankForLumeCloud() -> SyncedSportsFollow {
        SyncedSportsFollow(key: "", profileID: nil)
    }
}

// MARK: - recordingServer

nonisolated extension SyncedRecordingServer: LumeCloudPayloadMappable {
    static var lumeCloudType: String {
        "recordingServer"
    }

    var lumeCloudKey: String {
        LumeCloudPayloadCodec.recordingServerKey(id: id)
    }

    /// `token` is a pairing credential; it only ever leaves the device inside
    /// the sealed envelope.
    var lumeCloudFields: [String: JSONValue] {
        typealias Codec = LumeCloudPayloadCodec
        return [
            "id": Codec.wire(id),
            "kindRaw": .string(kindRaw),
            "name": .string(name),
            "baseURL": .string(baseURL),
            "serverID": Codec.wire(serverID),
            "deviceID": Codec.wire(deviceID),
            "token": .string(token),
            "isEnabled": .bool(isEnabled),
            "updatedAt": Codec.wire(updatedAt)
        ]
    }

    static func lumeCloudKey(for fields: LumeCloudPayloadCodec.Fields) throws -> String {
        try LumeCloudPayloadCodec.recordingServerKey(id: fields.uuid("id"))
    }

    func applyLumeCloudFields(_ fields: LumeCloudPayloadCodec.Fields) throws {
        let id = try fields.uuid("id")
        let kindRaw = try fields.string("kindRaw")
        let name = try fields.string("name")
        let baseURL = try fields.string("baseURL")
        let serverID = try fields.optionalUUID("serverID")
        let deviceID = try fields.optionalUUID("deviceID")
        let token = try fields.string("token")
        let isEnabled = try fields.bool("isEnabled")
        let updatedAt = try fields.date("updatedAt")

        self.id = id
        // Raw, not through `kind`: an unknown backend must survive to be written back.
        self.kindRaw = kindRaw
        self.name = name
        self.baseURL = baseURL
        self.serverID = serverID
        self.deviceID = deviceID
        self.token = token
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }

    static func makeBlankForLumeCloud() -> SyncedRecordingServer {
        SyncedRecordingServer(name: "", baseURL: "")
    }
}

// MARK: - liveTVPrefs

nonisolated extension SyncedLiveTVPreferences: LumeCloudPayloadMappable {
    static var lumeCloudType: String {
        "liveTVPrefs"
    }

    var lumeCloudKey: String {
        LumeCloudPayloadCodec.liveTVPreferencesKey
    }

    var lumeCloudFields: [String: JSONValue] {
        [
            "showsFavorites": .bool(showsFavorites),
            "showsRecentlyWatched": .bool(showsRecentlyWatched),
            "updatedAt": LumeCloudPayloadCodec.wire(updatedAt)
        ]
    }

    static func lumeCloudKey(for _: LumeCloudPayloadCodec.Fields) throws -> String {
        LumeCloudPayloadCodec.liveTVPreferencesKey
    }

    func applyLumeCloudFields(_ fields: LumeCloudPayloadCodec.Fields) throws {
        let showsFavorites = try fields.bool("showsFavorites")
        let showsRecentlyWatched = try fields.bool("showsRecentlyWatched")
        let updatedAt = try fields.date("updatedAt")

        self.showsFavorites = showsFavorites
        self.showsRecentlyWatched = showsRecentlyWatched
        self.updatedAt = updatedAt
    }

    static func makeBlankForLumeCloud() -> SyncedLiveTVPreferences {
        SyncedLiveTVPreferences(
            showsFavorites: LiveTVRailSettings.showsFavoritesDefault,
            showsRecentlyWatched: LiveTVRailSettings.showsRecentlyWatchedDefault
        )
    }
}

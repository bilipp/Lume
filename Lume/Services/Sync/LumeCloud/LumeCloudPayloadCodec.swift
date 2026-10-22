import Foundation
import LumeCloudKit
import SwiftData

/// A mirror model that travels as a Lume Cloud record (PROTOCOL.md §3).
///
/// `nonisolated`, conformances included: the transport encodes and decodes on
/// its own background `ModelContext`, and a bare conformance under default
/// `MainActor` isolation would be main-actor-isolated.
nonisolated protocol LumeCloudPayloadMappable: PersistentModel {
    /// The record's `type`.
    static var lumeCloudType: String { get }
    /// The logical key the record's payload `key` (and `rid`) derives from.
    var lumeCloudKey: String { get }
    var updatedAt: Date { get }
    /// Every `data` field this build knows, in wire form.
    var lumeCloudFields: [String: JSONValue] { get }
    /// The logical key the fields of a payload name.
    static func lumeCloudKey(for fields: LumeCloudPayloadCodec.Fields) throws -> String
    /// Overwrites every known field, identity included. Reads all fields before
    /// assigning any, so a malformed payload leaves the model untouched.
    func applyLumeCloudFields(_ fields: LumeCloudPayloadCodec.Fields) throws
    /// A blank model for `applyLumeCloudFields` to fill.
    static func makeBlankForLumeCloud() -> Self
    /// A fetch of at least the rows under `keys`; nil reads every row.
    static func lumeCloudRowsDescriptor(forKeys keys: Set<String>) -> FetchDescriptor<Self>?
}

nonisolated extension LumeCloudPayloadMappable {
    static func lumeCloudRowsDescriptor(forKeys _: Set<String>) -> FetchDescriptor<Self>? {
        nil
    }
}

/// Maps mirror models to and from `LumeCloudPayload` (PROTOCOL.md §2.5, §3).
///
/// Store bookkeeping on `encoded(_:previous:)`: those canonical bytes are what
/// dirty detection compares against `LumeCloudRecordState.lastSyncedPayload`.
/// Payloads carry credentials and user state, so neither payloads nor field
/// values ever reach a log line or a thrown error.
nonisolated enum LumeCloudPayloadCodec {
    enum CodecError: Error, Equatable {
        case unsupportedVersion
        case wrongType
        case keyMismatch
        case missingField(String)
        case invalidField(String)
    }

    // MARK: Encoding

    /// The payload for `model`. Fields this build doesn't know, and top-level
    /// `extra`, carry over from `previous` (the last-synced bytes of the same
    /// record) so a newer client's additions are written back unchanged.
    static func payload<Model: LumeCloudPayloadMappable>(for model: Model, previous: Data?) -> LumeCloudPayload {
        let key = model.lumeCloudKey
        var data: [String: JSONValue] = [:]
        var extra: [String: JSONValue] = [:]
        if let previous, let base = try? LumeCloudPayload.decode(previous),
           base.type == Model.lumeCloudType, base.key == key
        {
            data = base.data
            extra = base.extra
        }
        data.merge(model.lumeCloudFields) { _, known in known }
        return LumeCloudPayload(type: Model.lumeCloudType, key: key, data: data, extra: extra)
    }

    /// The canonical bytes of `payload(for:previous:)`.
    static func encoded(_ model: some LumeCloudPayloadMappable, previous: Data?) throws -> Data {
        try payload(for: model, previous: previous).encoded()
    }

    // MARK: Decoding

    /// A new, uninserted model holding `payload`.
    static func makeModel<Model: LumeCloudPayloadMappable>(
        from payload: LumeCloudPayload,
        as _: Model.Type = Model.self
    ) throws -> Model {
        let fields = try validatedFields(of: payload, as: Model.self)
        let model = Model.makeBlankForLumeCloud()
        try model.applyLumeCloudFields(fields)
        return model
    }

    /// Overwrites `model` with `payload`, which must be the same record.
    static func apply<Model: LumeCloudPayloadMappable>(_ payload: LumeCloudPayload, to model: Model) throws {
        let fields = try validatedFields(of: payload, as: Model.self)
        guard model.lumeCloudKey == payload.key else { throw CodecError.keyMismatch }
        try model.applyLumeCloudFields(fields)
    }

    private static func validatedFields<Model: LumeCloudPayloadMappable>(
        of payload: LumeCloudPayload,
        as _: Model.Type
    ) throws -> Fields {
        guard payload.v <= LumeCloudPayload.currentVersion else { throw CodecError.unsupportedVersion }
        guard payload.type == Model.lumeCloudType else { throw CodecError.wrongType }
        let fields = Fields(payload.data)
        guard try Model.lumeCloudKey(for: fields) == payload.key else { throw CodecError.keyMismatch }
        return fields
    }

    // MARK: Wire values

    /// Epoch milliseconds, rounded to the nearest millisecond: a date decoded
    /// from N ms re-encodes to exactly N despite binary floating point.
    static func wire(_ date: Date) -> JSONValue {
        .number((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func wire(_ date: Date?) -> JSONValue {
        date.map { wire($0) } ?? .null
    }

    static func wire(_ uuid: UUID) -> JSONValue {
        .string(uuid.uuidString)
    }

    static func wire(_ uuid: UUID?) -> JSONValue {
        uuid.map { wire($0) } ?? .null
    }

    static func wire(_ int: Int) -> JSONValue {
        .number(Double(int))
    }

    static func wire(_ int: Int?) -> JSONValue {
        int.map { wire($0) } ?? .null
    }

    static func wire(_ string: String?) -> JSONValue {
        string.map { .string($0) } ?? .null
    }

    /// Canonical JSON can't carry NaN or infinity.
    static func wire(_ double: Double) -> JSONValue {
        .number(double.isFinite ? double : 0)
    }

    /// A payload's `data`, read with typed accessors. A required field that is
    /// absent or `null`, or any field of the wrong JSON type, throws.
    struct Fields {
        let raw: [String: JSONValue]

        init(_ raw: [String: JSONValue]) {
            self.raw = raw
        }

        private func required(_ name: String) throws -> JSONValue {
            guard let value = raw[name], !value.isNull else { throw CodecError.missingField(name) }
            return value
        }

        private func optional(_ name: String) -> JSONValue? {
            guard let value = raw[name], !value.isNull else { return nil }
            return value
        }

        private func typed<T>(_ name: String, _ value: JSONValue, _ read: (JSONValue) -> T?) throws -> T {
            guard let result = read(value) else { throw CodecError.invalidField(name) }
            return result
        }

        func string(_ name: String) throws -> String {
            try typed(name, required(name), \.stringValue)
        }

        func optionalString(_ name: String) throws -> String? {
            try optional(name).map { try typed(name, $0, \.stringValue) }
        }

        func bool(_ name: String) throws -> Bool {
            try typed(name, required(name), \.boolValue)
        }

        func int(_ name: String) throws -> Int {
            try typed(name, required(name), \.intValue)
        }

        func optionalInt(_ name: String) throws -> Int? {
            try optional(name).map { try typed(name, $0, \.intValue) }
        }

        func double(_ name: String) throws -> Double {
            try typed(name, required(name), \.doubleValue)
        }

        func date(_ name: String) throws -> Date {
            try Date(lumeCloudMilliseconds: typed(name, required(name), \.doubleValue))
        }

        func optionalDate(_ name: String) throws -> Date? {
            try optional(name).map { try Date(lumeCloudMilliseconds: typed(name, $0, \.doubleValue)) }
        }

        func uuid(_ name: String) throws -> UUID {
            try typed(name, required(name)) { $0.stringValue.flatMap(UUID.init(uuidString:)) }
        }

        func optionalUUID(_ name: String) throws -> UUID? {
            try optional(name).map { value in
                try typed(name, value) { $0.stringValue.flatMap(UUID.init(uuidString:)) }
            }
        }
    }
}

nonisolated extension Date {
    /// A Lume Cloud timestamp: milliseconds since 1970.
    init(lumeCloudMilliseconds milliseconds: Double) {
        self.init(timeIntervalSince1970: milliseconds / 1000)
    }
}

// MARK: - Logical keys

nonisolated extension LumeCloudPayloadCodec {
    static func playlistKey(id: UUID) -> String {
        "playlist/\(id.uuidString)"
    }

    /// A nil `profileID` (a legacy record) is the literal `none`.
    static func contentKey(profileID: UUID?, contentId: String) -> String {
        "content/\(profileID?.uuidString ?? "none")/\(contentId)"
    }

    static func profileKey(id: UUID) -> String {
        "profile/\(id.uuidString)"
    }

    static func epgSourceKey(id: UUID) -> String {
        "epgSource/\(id.uuidString)"
    }

    static let parentalPINKey = "parentalPin"

    static func categoryRestrictionKey(categoryID: String) -> String {
        "categoryRestriction/\(categoryID)"
    }

    /// A nil `profileID` is the literal `none`, as for content.
    static func sportsFollowKey(profileID: UUID?, key: String) -> String {
        "sportsFollow/\(profileID?.uuidString ?? "none")/\(key)"
    }

    static func recordingServerKey(id: UUID) -> String {
        "recordingServer/\(id.uuidString)"
    }

    static let liveTVPreferencesKey = "liveTVPrefs"
}

// MARK: - playlist

nonisolated extension SyncedPlaylist: LumeCloudPayloadMappable {
    static var lumeCloudType: String {
        "playlist"
    }

    var lumeCloudKey: String {
        LumeCloudPayloadCodec.playlistKey(id: id)
    }

    var lumeCloudFields: [String: JSONValue] {
        typealias Codec = LumeCloudPayloadCodec
        return [
            "id": Codec.wire(id),
            "name": .string(name),
            "serverURL": .string(serverURL),
            "username": .string(username),
            "password": .string(password),
            "macAddress": .string(macAddress),
            "sourceTypeRaw": .string(sourceTypeRaw),
            "epgURL": Codec.wire(epgURL),
            "syncEnabled": .bool(syncEnabled),
            "hiddenTabsRaw": .string(hiddenTabsRaw),
            "updatedAt": Codec.wire(updatedAt)
        ]
    }

    static func lumeCloudKey(for fields: LumeCloudPayloadCodec.Fields) throws -> String {
        try LumeCloudPayloadCodec.playlistKey(id: fields.uuid("id"))
    }

    func applyLumeCloudFields(_ fields: LumeCloudPayloadCodec.Fields) throws {
        let id = try fields.uuid("id")
        let name = try fields.string("name")
        let serverURL = try fields.string("serverURL")
        let username = try fields.string("username")
        let password = try fields.string("password")
        let macAddress = try fields.string("macAddress")
        let sourceTypeRaw = try fields.string("sourceTypeRaw")
        let epgURL = try fields.optionalString("epgURL")
        let syncEnabled = try fields.bool("syncEnabled")
        let hiddenTabsRaw = try fields.string("hiddenTabsRaw")
        let updatedAt = try fields.date("updatedAt")

        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.macAddress = macAddress
        self.sourceTypeRaw = sourceTypeRaw
        self.epgURL = epgURL
        self.syncEnabled = syncEnabled
        self.hiddenTabsRaw = hiddenTabsRaw
        self.updatedAt = updatedAt
    }

    static func makeBlankForLumeCloud() -> SyncedPlaylist {
        SyncedPlaylist(
            id: UUID(),
            name: "",
            serverURL: "",
            username: "",
            password: "",
            sourceTypeRaw: PlaylistSourceType.xtream.rawValue,
            epgURL: nil,
            syncEnabled: true
        )
    }
}

// MARK: - content

nonisolated extension UserContentState: LumeCloudPayloadMappable {
    static var lumeCloudType: String {
        "content"
    }

    var lumeCloudKey: String {
        LumeCloudPayloadCodec.contentKey(profileID: profileID, contentId: contentId)
    }

    static func lumeCloudRowsDescriptor(forKeys keys: Set<String>) -> FetchDescriptor<UserContentState>? {
        var contentIds: [String] = []
        for key in keys {
            guard case let .content(_, contentId) = LumeCloudLogicalKey(key) else { return nil }
            contentIds.append(contentId)
        }
        return FetchDescriptor(predicate: #Predicate { contentIds.contains($0.contentId) })
    }

    var lumeCloudFields: [String: JSONValue] {
        typealias Codec = LumeCloudPayloadCodec
        return [
            "contentId": .string(contentId),
            "kindRaw": .string(kindRaw),
            "profileID": Codec.wire(profileID),
            "watchProgress": Codec.wire(watchProgress),
            "isWatched": .bool(isWatched),
            "lastWatchedDate": Codec.wire(lastWatchedDate),
            "isFavorite": .bool(isFavorite),
            "addedToWatchlistDate": Codec.wire(addedToWatchlistDate),
            "favoriteOrder": Codec.wire(favoriteOrder),
            "isHidden": .bool(isHidden),
            "customOrder": Codec.wire(customOrder),
            "recommendationVoteRaw": Codec.wire(recommendationVoteRaw),
            "updatedAt": Codec.wire(updatedAt)
        ]
    }

    static func lumeCloudKey(for fields: LumeCloudPayloadCodec.Fields) throws -> String {
        try LumeCloudPayloadCodec.contentKey(
            profileID: fields.optionalUUID("profileID"),
            contentId: fields.string("contentId")
        )
    }

    func applyLumeCloudFields(_ fields: LumeCloudPayloadCodec.Fields) throws {
        let contentId = try fields.string("contentId")
        let kindRaw = try fields.string("kindRaw")
        let profileID = try fields.optionalUUID("profileID")
        let watchProgress = try fields.double("watchProgress")
        let isWatched = try fields.bool("isWatched")
        let lastWatchedDate = try fields.optionalDate("lastWatchedDate")
        let isFavorite = try fields.bool("isFavorite")
        let addedToWatchlistDate = try fields.optionalDate("addedToWatchlistDate")
        let favoriteOrder = try fields.optionalInt("favoriteOrder")
        let isHidden = try fields.bool("isHidden")
        let customOrder = try fields.optionalInt("customOrder")
        let recommendationVoteRaw = try fields.int("recommendationVoteRaw")
        let updatedAt = try fields.date("updatedAt")

        self.contentId = contentId
        // Raw, not through `kind`: an unknown kind must survive to be written back.
        self.kindRaw = kindRaw
        self.profileID = profileID
        self.watchProgress = watchProgress
        self.isWatched = isWatched
        self.lastWatchedDate = lastWatchedDate
        self.isFavorite = isFavorite
        self.addedToWatchlistDate = addedToWatchlistDate
        self.favoriteOrder = favoriteOrder
        self.isHidden = isHidden
        self.customOrder = customOrder
        self.recommendationVoteRaw = recommendationVoteRaw
        self.updatedAt = updatedAt
    }

    static func makeBlankForLumeCloud() -> UserContentState {
        UserContentState(contentId: "", kind: .movie)
    }
}

// MARK: - profile

nonisolated extension UserProfile: LumeCloudPayloadMappable {
    static var lumeCloudType: String {
        "profile"
    }

    var lumeCloudKey: String {
        LumeCloudPayloadCodec.profileKey(id: id)
    }

    var lumeCloudFields: [String: JSONValue] {
        typealias Codec = LumeCloudPayloadCodec
        return [
            "id": Codec.wire(id),
            "name": .string(name),
            "symbolName": .string(symbolName),
            "colorRaw": .string(colorRaw),
            "createdAt": Codec.wire(createdAt),
            "sortOrder": Codec.wire(sortOrder),
            "isChild": .bool(isChild),
            "updatedAt": Codec.wire(updatedAt)
        ]
    }

    static func lumeCloudKey(for fields: LumeCloudPayloadCodec.Fields) throws -> String {
        try LumeCloudPayloadCodec.profileKey(id: fields.uuid("id"))
    }

    func applyLumeCloudFields(_ fields: LumeCloudPayloadCodec.Fields) throws {
        let id = try fields.uuid("id")
        let name = try fields.string("name")
        let symbolName = try fields.string("symbolName")
        let colorRaw = try fields.string("colorRaw")
        let createdAt = try fields.date("createdAt")
        let sortOrder = try fields.int("sortOrder")
        let isChild = try fields.bool("isChild")
        let updatedAt = try fields.date("updatedAt")

        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.colorRaw = colorRaw
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.isChild = isChild
        self.updatedAt = updatedAt
    }

    static func makeBlankForLumeCloud() -> UserProfile {
        UserProfile(name: "")
    }
}

// MARK: - epgSource

nonisolated extension SyncedEPGSource: LumeCloudPayloadMappable {
    static var lumeCloudType: String {
        "epgSource"
    }

    var lumeCloudKey: String {
        LumeCloudPayloadCodec.epgSourceKey(id: id)
    }

    var lumeCloudFields: [String: JSONValue] {
        typealias Codec = LumeCloudPayloadCodec
        return [
            "id": Codec.wire(id),
            "name": .string(name),
            "url": .string(url),
            "isEnabled": .bool(isEnabled),
            "updatedAt": Codec.wire(updatedAt)
        ]
    }

    static func lumeCloudKey(for fields: LumeCloudPayloadCodec.Fields) throws -> String {
        try LumeCloudPayloadCodec.epgSourceKey(id: fields.uuid("id"))
    }

    func applyLumeCloudFields(_ fields: LumeCloudPayloadCodec.Fields) throws {
        let id = try fields.uuid("id")
        let name = try fields.string("name")
        let url = try fields.string("url")
        let isEnabled = try fields.bool("isEnabled")
        let updatedAt = try fields.date("updatedAt")

        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }

    static func makeBlankForLumeCloud() -> SyncedEPGSource {
        SyncedEPGSource(id: UUID(), name: "", url: "", isEnabled: true)
    }
}

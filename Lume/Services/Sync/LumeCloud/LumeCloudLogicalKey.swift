import Foundation
import LumeCloudKit

// MARK: - Dispatch

nonisolated extension LumeCloudPayloadCodec {
    /// Every mirror model that travels as a record.
    static var mappableModels: [any LumeCloudPayloadMappable.Type] {
        [
            SyncedPlaylist.self, UserContentState.self, UserProfile.self, SyncedEPGSource.self,
            SyncedParentalPIN.self, SyncedCategoryRestriction.self, SyncedSportsFollow.self,
            SyncedRecordingServer.self, SyncedLiveTVPreferences.self
        ]
    }

    /// The mirror model a record `type` maps to. Nil for a type this build
    /// doesn't know: the transport keeps such a record and never deletes it.
    static func modelType(forRecordType type: String) -> (any LumeCloudPayloadMappable.Type)? {
        mappableModels.first { $0.lumeCloudType == type }
    }

    /// A new, uninserted model for `payload`, dispatched on its `type`. Nil for
    /// a type this build doesn't know.
    static func makeAnyModel(from payload: LumeCloudPayload) throws -> (any LumeCloudPayloadMappable)? {
        guard let modelType = modelType(forRecordType: payload.type) else { return nil }
        return try makeModel(from: payload, as: modelType)
    }
}

/// A parsed logical key (PROTOCOL.md §3). Only the canonical spelling
/// parses — uppercase UUIDs, `none` for a nil profile — so a parsed key
/// always renders back to the string it came from.
nonisolated enum LumeCloudLogicalKey: Hashable {
    case playlist(id: UUID)
    case content(profileID: UUID?, contentId: String)
    case profile(id: UUID)
    case epgSource(id: UUID)
    case parentalPIN
    case categoryRestriction(categoryID: String)
    case sportsFollow(profileID: UUID?, key: String)
    case recordingServer(id: UUID)
    case liveTVPreferences

    init?(_ key: String) {
        guard let parsed = Self.parse(key), parsed.key == key else { return nil }
        self = parsed
    }

    private static func parse(_ key: String) -> Self? {
        switch key {
        case LumeCloudPayloadCodec.parentalPINKey: return .parentalPIN
        case LumeCloudPayloadCodec.liveTVPreferencesKey: return .liveTVPreferences
        default: break
        }
        guard let slash = key.firstIndex(of: "/") else { return nil }
        return parse(type: String(key[..<slash]), rest: String(key[key.index(after: slash)...]))
    }

    private static func parse(type: String, rest: String) -> Self? {
        switch type {
        case SyncedPlaylist.lumeCloudType: UUID(uuidString: rest).map { .playlist(id: $0) }
        case UserContentState.lumeCloudType:
            profileScoped(rest).map { .content(profileID: $0.profileID, contentId: $0.id) }
        case UserProfile.lumeCloudType: UUID(uuidString: rest).map { .profile(id: $0) }
        case SyncedEPGSource.lumeCloudType: UUID(uuidString: rest).map { .epgSource(id: $0) }
        case SyncedCategoryRestriction.lumeCloudType: rest.isEmpty ? nil : .categoryRestriction(categoryID: rest)
        case SyncedSportsFollow.lumeCloudType:
            profileScoped(rest).map { .sportsFollow(profileID: $0.profileID, key: $0.id) }
        case SyncedRecordingServer.lumeCloudType: UUID(uuidString: rest).map { .recordingServer(id: $0) }
        default: nil
        }
    }

    var key: String {
        typealias Codec = LumeCloudPayloadCodec
        return switch self {
        case let .playlist(id): Codec.playlistKey(id: id)
        case let .content(profileID, contentId): Codec.contentKey(profileID: profileID, contentId: contentId)
        case let .profile(id): Codec.profileKey(id: id)
        case let .epgSource(id): Codec.epgSourceKey(id: id)
        case .parentalPIN: Codec.parentalPINKey
        case let .categoryRestriction(categoryID): Codec.categoryRestrictionKey(categoryID: categoryID)
        case let .sportsFollow(profileID, key): Codec.sportsFollowKey(profileID: profileID, key: key)
        case let .recordingServer(id): Codec.recordingServerKey(id: id)
        case .liveTVPreferences: Codec.liveTVPreferencesKey
        }
    }

    /// The mirror model a record under this key decodes to.
    var modelType: any LumeCloudPayloadMappable.Type {
        switch self {
        case .playlist: SyncedPlaylist.self
        case .content: UserContentState.self
        case .profile: UserProfile.self
        case .epgSource: SyncedEPGSource.self
        case .parentalPIN: SyncedParentalPIN.self
        case .categoryRestriction: SyncedCategoryRestriction.self
        case .sportsFollow: SyncedSportsFollow.self
        case .recordingServer: SyncedRecordingServer.self
        case .liveTVPreferences: SyncedLiveTVPreferences.self
        }
    }

    /// The record `type` a payload under this key carries.
    var type: String {
        modelType.lumeCloudType
    }

    /// `<profileUUID|none>/<id>`, where `id` may itself contain slashes.
    private static func profileScoped(_ rest: String) -> (profileID: UUID?, id: String)? {
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let profile = String(rest[..<slash])
        let id = String(rest[rest.index(after: slash)...])
        guard !id.isEmpty else { return nil }
        if profile == "none" { return (nil, id) }
        guard let profileID = UUID(uuidString: profile) else { return nil }
        return (profileID, id)
    }
}

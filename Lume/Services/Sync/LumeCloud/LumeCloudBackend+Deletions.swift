import Foundation
import OSLog

/// User deletions become explicit tombstones; the server never infers one
/// from a missing mirror row.
extension LumeCloudBackend {
    /// The playlist and every profile's content state under it.
    func recordPlaylistDeletion(id: UUID) async {
        let prefix = id.uuidString
        await recordDeletions(of: "playlist") { transport in
            let contentKeys = try await transport.syncedLogicalKeys(containing: [prefix]).filter { key in
                guard case let .content(_, contentId)? = LumeCloudLogicalKey(key) else { return false }
                return contentId.hasPrefix(prefix)
            }
            return [LumeCloudPayloadCodec.playlistKey(id: id)] + contentKeys
        }
    }

    /// The profile, its content state and its sports follows. Rows without a
    /// profile belong to the default profile.
    func recordProfileDeletion(id: UUID) async {
        let isDefault = id == UserProfile.defaultProfileID
        func owned(_ profileID: UUID?) -> Bool {
            profileID == id || (isDefault && profileID == nil)
        }
        let profileSegments = [id.uuidString] + (isDefault ? ["none"] : [])
        let fragments = profileSegments.flatMap { segment in
            [UserContentState.lumeCloudType, SyncedSportsFollow.lumeCloudType].map { "\($0)/\(segment)/" }
        }
        await recordDeletions(of: "profile") { transport in
            let ownedKeys = try await transport.syncedLogicalKeys(containing: fragments).filter { key in
                switch LumeCloudLogicalKey(key) {
                case let .content(profileID, _)?, let .sportsFollow(profileID, _)?: owned(profileID)
                default: false
                }
            }
            return [LumeCloudPayloadCodec.profileKey(id: id)] + ownedKeys
        }
    }

    /// `subject` names the deleted thing's type for the log, never its id.
    private func recordDeletions(
        of subject: String,
        keys: (LumeCloudTransport) async throws -> [String]
    ) async {
        guard let transport else { return }
        do {
            try await transport.recordDeletions(logicalKeys: keys(transport))
        } catch {
            Logger.sync.error("Lume Cloud couldn't record a \(subject, privacy: .public) deletion")
        }
    }
}

//
//  LumeCloudVectorExportTests+Conflicts.swift
//  LumeTests
//
//  merge.json `conflicts`: whole payloads through the transport's conflict
//  merge (`LumeCloudTransport.mergedPayload`), one case per collection.
//

import Foundation
@testable import Lume
import LumeCloudKit

extension LumeCloudVectorExportTests {
    private static func conflict<Model: LumeCloudConflictMerging>(
        _ name: String,
        local: Model,
        remote: Model,
        remoteOnlyFields: [String: JSONValue] = [:]
    ) throws -> ConflictVector {
        let localBytes = try LumeCloudPayloadCodec.encoded(local, previous: nil)
        var remotePayload = LumeCloudPayloadCodec.payload(for: remote, previous: nil)
        remotePayload.data.merge(remoteOnlyFields) { known, _ in known }
        let remoteBytes = try remotePayload.encoded()
        let merged = try LumeCloudTransport.mergedPayload(local: localBytes, remote: remoteBytes, as: Model.self)
        return try ConflictVector(
            name: name,
            type: Model.lumeCloudType,
            local: LumeCloudVectorFiles.json(localBytes),
            remote: LumeCloudVectorFiles.json(remoteBytes),
            merged: LumeCloudVectorFiles.json(merged)
        )
    }

    // swiftlint:disable:next function_body_length
    static func conflictVectors() throws -> [ConflictVector] {
        let older = date(1_760_000_000_000)
        let newer = date(1_760_000_600_000)
        let playlistID = playlistID
        let profileID = profileID
        let contentId = "\(playlistID.uuidString)-movie-1001"
        let serverID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000DD01")!
        let guideID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000EE01")!

        func playlist(_ name: String, _ updatedAt: Date) -> SyncedPlaylist {
            SyncedPlaylist(
                id: playlistID,
                name: name,
                serverURL: "http://provider.example:8080",
                username: "viewer",
                password: "secret",
                sourceTypeRaw: PlaylistSourceType.xtream.rawValue,
                epgURL: nil,
                syncEnabled: true,
                updatedAt: updatedAt
            )
        }
        func profile(name: String, isChild: Bool, updatedAt: Date) -> UserProfile {
            UserProfile(
                id: profileID,
                name: name,
                symbolName: "star.fill",
                colorRaw: ProfileColor.teal.rawValue,
                sortOrder: 1,
                isChild: isChild,
                createdAt: date(1_759_000_000_000),
                updatedAt: updatedAt
            )
        }
        func server(name: String, token: String, updatedAt: Date) -> SyncedRecordingServer {
            SyncedRecordingServer(
                id: serverID,
                name: name,
                baseURL: "http://recorder.example:8089",
                token: token,
                updatedAt: updatedAt
            )
        }

        return try [
            conflict("remote wins", local: playlist("Harbor Lights (Home)", newer), remote: playlist("Harbor Lights", older)),
            conflict(
                "field policy, the later updatedAt, and a remote-only field survives",
                local: UserContentState(
                    contentId: contentId, kind: .movie, profileID: profileID, watchProgress: 1800, isWatched: false,
                    lastWatchedDate: older, isFavorite: false, favoriteOrder: 2, updatedAt: older
                ),
                remote: UserContentState(
                    contentId: contentId, kind: .movie, profileID: profileID, watchProgress: 1200, isWatched: true,
                    lastWatchedDate: newer, isFavorite: true, recommendationVoteRaw: -1, isHidden: true, updatedAt: newer
                ),
                remoteOnlyFields: ["futureField": ["nested": "kept"]]
            ),
            conflict(
                "the newer side wins and isChild true survives",
                local: profile(name: "Harbor Room", isChild: true, updatedAt: older),
                remote: profile(name: "Harbor", isChild: false, updatedAt: newer)
            ),
            conflict(
                "remote wins",
                local: SyncedEPGSource(id: guideID, name: "Meadow Guide", url: "https://guide.example/a.xml", isEnabled: false, updatedAt: newer),
                remote: SyncedEPGSource(id: guideID, name: "Meadow Guide HD", url: "https://guide.example/b.xml", isEnabled: true, updatedAt: older)
            ),
            conflict(
                "remote wins",
                local: SyncedParentalPIN(pinHash: String(repeating: "fedcba9876543210", count: 4), updatedAt: newer),
                remote: SyncedParentalPIN(pinHash: String(repeating: "0123456789abcdef", count: 4), updatedAt: older)
            ),
            conflict(
                "restricted on both sides",
                local: SyncedCategoryRestriction(categoryID: "\(playlistID.uuidString)-live-5", updatedAt: newer),
                remote: SyncedCategoryRestriction(categoryID: "\(playlistID.uuidString)-live-5", updatedAt: older)
            ),
            conflict(
                "the newer side wins",
                local: SyncedSportsFollow(key: "demo:soccer/meadow.1:4021", profileID: profileID, sortOrder: 2, updatedAt: newer),
                remote: SyncedSportsFollow(key: "demo:soccer/meadow.1:4021", profileID: profileID, sortOrder: 5, updatedAt: older)
            ),
            conflict(
                "an exact updatedAt tie: remote wins as a whole record",
                local: server(name: "Basement Recorder", token: "fictional-token-2", updatedAt: newer),
                remote: server(name: "Attic Recorder", token: "fictional-token-1", updatedAt: newer)
            ),
            conflict(
                "remote wins",
                local: SyncedLiveTVPreferences(showsFavorites: false, showsRecentlyWatched: true, updatedAt: newer),
                remote: SyncedLiveTVPreferences(showsFavorites: true, showsRecentlyWatched: false, updatedAt: older)
            )
        ]
    }
}

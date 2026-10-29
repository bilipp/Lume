//
//  LumeCloudVectorExportTests+Merge.swift
//  LumeTests
//
//  merge.json: the three-way merge (`CloudSyncMerge.reconcile`) with each
//  collection's conflict policy, and the payload-level conflict merge the Lume
//  Cloud transport applies when both sides changed a record.
//

import Foundation
@testable import Lume
import LumeCloudKit

extension LumeCloudVectorExportTests {
    struct MergeDocument: Encodable {
        var format = "lume-cloud-merge-vectors"
        var notes: [String]
        var reconcile: [ReconcileVector]
        var conflicts: [ConflictVector]
    }

    struct ReconcileVector: Encodable {
        var name: String
        var collection: String
        var base: JSONValue
        var local: JSONValue
        var remote: JSONValue
        var verdict: String
        var value: JSONValue
    }

    struct ConflictVector: Encodable {
        var name: String
        var type: String
        var local: JSONValue
        var remote: JSONValue
        var merged: JSONValue
    }

    static func mergeDocument() throws -> MergeDocument {
        try MergeDocument(
            notes: [
                "reconcile: base is the value both sides last agreed on (lastSyncedPayload / the shadow), local the device's value, remote the other side's.",
                "null means absent: never synced, or deleted.",
                "verdict: noChange (write nothing), pushToRemote (write value to the remote side), pullToLocal (write value locally), writeBoth (write value to both).",
                "value null with pushToRemote or pullToLocal is a deletion; with noChange it is unused.",
                "Every verdict re-baselines to the written value.",
                "reconcile values carry only the fields the merge compares, in payload wire form (epoch-ms dates, uppercase UUIDs). An optional field that is left out is nil.",
                "parentalPin compares pinHash only; profile, sportsFollow and recordingServer compare updatedAt too because their policy needs it.",
                "conflicts: both sides changed a record to different values. merged is the payload the transport writes to the mirror and pushes; fields only the remote payload carries survive."
            ],
            reconcile: genericReconcileVectors() + contentReconcileVectors() + settingsReconcileVectors()
                + mirrorReconcileVectors(),
            conflicts: conflictVectors()
        )
    }

    // MARK: Reconcile

    /// One collection's merge policy and wire form.
    private struct MergeCollection<Value: Equatable> {
        let name: String
        let merge: (Value, Value) -> Value
        let json: (Value) throws -> JSONValue

        func vector(_ caseName: String, base: Value?, local: Value?, remote: Value?) throws -> ReconcileVector {
            let verdict = CloudSyncMerge.reconcile(local: local, cloud: remote, shadow: base, mergeConflict: merge)
            let (label, value): (String, Value?) = switch verdict {
            case .noChange: ("noChange", nil)
            case let .pushToCloud(value): ("pushToRemote", value)
            case let .pullToLocal(value): ("pullToLocal", value)
            case let .writeBoth(value): ("writeBoth", value)
            }
            return try ReconcileVector(
                name: caseName,
                collection: name,
                base: wire(base),
                local: wire(local),
                remote: wire(remote),
                verdict: label,
                value: wire(value)
            )
        }

        private func wire(_ value: Value?) throws -> JSONValue {
            try value.map(json) ?? .null
        }
    }

    private static func wire(_ value: some Encodable) throws -> JSONValue {
        try LumeCloudVectorFiles.json(encoding: value)
    }

    /// Every verdict shape, on playlist config (cloud-wins conflicts).
    private static func genericReconcileVectors() throws -> [ReconcileVector] {
        let base = PlaylistConfigValues(
            name: "Harbor Lights",
            serverURL: "http://provider.example:8080",
            username: "viewer",
            password: "secret",
            sourceTypeRaw: PlaylistSourceType.xtream.rawValue,
            epgURL: nil,
            syncEnabled: true
        )
        var local = base
        local.name = "Harbor Lights (Home)"
        var remote = base
        remote.hiddenTabsRaw = "series"
        let collection = MergeCollection(name: "playlist", merge: PlaylistConfigValues.mergeConflict, json: wire)
        let cases: [(String, PlaylistConfigValues?, PlaylistConfigValues?, PlaylistConfigValues?)] = [
            ("unchanged on both sides", base, base, base),
            ("local edit is pushed", base, local, base),
            ("remote edit is pulled", base, base, remote),
            ("local deletion is pushed", base, nil, base),
            ("remote deletion is pulled", base, base, nil),
            ("created locally", nil, local, nil),
            ("created remotely", nil, nil, remote),
            ("same edit on both sides only re-baselines", base, local, local),
            ("conflicting edits: remote wins", base, local, remote),
            ("local edit survives a remote deletion", base, local, nil),
            ("remote edit survives a local deletion", base, nil, remote),
            ("deleted on both sides", base, nil, nil),
            ("created differently on both sides: remote wins", nil, local, remote)
        ]
        return try cases.map { name, base, local, remote in
            try collection.vector(name, base: base, local: local, remote: remote)
        }
    }

    private static func contentReconcileVectors() throws -> [ReconcileVector] {
        let earlier = date(1_760_000_000_000)
        let later = date(1_760_000_600_000)
        let base = ContentStateValues(
            watchProgress: 600,
            isWatched: false,
            lastWatchedDate: earlier,
            isFavorite: true,
            addedToWatchlistDate: nil,
            favoriteOrder: nil
        )
        func edit(_ change: (inout ContentStateValues) -> Void) -> ContentStateValues {
            var value = base
            change(&value)
            return value
        }
        let collection = MergeCollection(name: "content", merge: ContentStateValues.mergeConflict, json: wire)
        let cases: [(String, ContentStateValues?, ContentStateValues?, ContentStateValues?)] = [
            (
                "furthest progress wins",
                base,
                edit { $0.watchProgress = 1800; $0.lastWatchedDate = earlier },
                edit { $0.watchProgress = 1200; $0.lastWatchedDate = later }
            ),
            ("watched on either side stays watched", base, edit { $0.isWatched = true }, edit { $0.watchProgress = 900 }),
            ("a conflict never loses a favorite", base, edit { $0.isFavorite = false }, edit { $0.watchProgress = 900 }),
            ("an unfavorite that is the only edit wins", base, edit { $0.isFavorite = false }, base),
            (
                "the later last-watched date and the earlier watchlist date win",
                base,
                edit { $0.lastWatchedDate = later; $0.addedToWatchlistDate = later },
                edit { $0.watchProgress = 700; $0.addedToWatchlistDate = earlier }
            ),
            ("both favorite orders set: local wins", base, edit { $0.favoriteOrder = 2 }, edit { $0.favoriteOrder = 5 }),
            ("a concrete favorite order beats none", base, edit { $0.watchProgress = 650 }, edit { $0.favoriteOrder = 5 }),
            ("an explicit vote beats none", base, edit { $0.watchProgress = 650 }, edit { $0.recommendationVoteRaw = 1 }),
            ("an up/down vote clash resolves to down", base, edit { $0.recommendationVoteRaw = 1 }, edit { $0.recommendationVoteRaw = -1 }),
            ("hidden on either side stays hidden", base, edit { $0.isHidden = true }, edit { $0.customOrder = 3 }),
            ("both custom orders set: local wins", base, edit { $0.customOrder = 1 }, edit { $0.customOrder = 4 }),
            ("a cleared item deletes its record", base, nil, base)
        ]
        return try cases.map { name, base, local, remote in
            try collection.vector(name, base: base, local: local, remote: remote)
        }
    }

    private static func settingsReconcileVectors() throws -> [ReconcileVector] {
        let guide = EPGSourceValues(name: "Meadow Guide", url: "https://guide.example/xmltv.xml.gz", isEnabled: true)
        var localGuide = guide
        localGuide.isEnabled = false
        var remoteGuide = guide
        remoteGuide.name = "Meadow Guide HD"

        let pin = ParentalPINValues(hash: String(repeating: "0123456789abcdef", count: 4))
        let otherPIN = ParentalPINValues(hash: String(repeating: "fedcba9876543210", count: 4))
        let thirdPIN = ParentalPINValues(hash: String(repeating: "00112233aabbccdd", count: 4))
        let guides = MergeCollection(name: "epgSource", merge: EPGSourceValues.mergeConflict, json: wire)
        let pins = MergeCollection(name: "parentalPin", merge: ParentalPINValues.mergeConflict) { pin in
            JSONValue.object(["pinHash": .string(pin.hash)])
        }
        let restrictions = MergeCollection(name: "categoryRestriction", merge: CategoryRestrictionValues.mergeConflict, json: wire)
        let preferences = MergeCollection(name: "liveTVPrefs", merge: LiveTVPreferenceValues.mergeConflict, json: wire)

        let restricted = CategoryRestrictionValues()
        let prefs = LiveTVPreferenceValues(showsFavorites: true, showsRecentlyWatched: true)

        return try [
            guides.vector("conflicting edits: remote wins", base: guide, local: localGuide, remote: remoteGuide),
            pins.vector("conflicting PINs: remote wins", base: pin, local: otherPIN, remote: thirdPIN),
            pins.vector("a PIN turned off is pushed as a deletion", base: pin, local: nil, remote: pin),
            restrictions.vector("a lifted restriction is pushed as a deletion", base: restricted, local: nil, remote: restricted),
            restrictions.vector("restricted on both sides", base: nil, local: restricted, remote: restricted),
            preferences.vector(
                "conflicting switches: remote wins",
                base: prefs,
                local: LiveTVPreferenceValues(showsFavorites: false, showsRecentlyWatched: true),
                remote: LiveTVPreferenceValues(showsFavorites: true, showsRecentlyWatched: false)
            )
        ]
    }

    // swiftlint:disable:next function_body_length
    private static func mirrorReconcileVectors() throws -> [ReconcileVector] {
        let older = date(1_760_000_000_000)
        let newer = date(1_760_000_600_000)
        let profile = ProfileValues(
            name: "Harbor",
            symbolName: "star.fill",
            colorRaw: ProfileColor.teal.rawValue,
            createdAt: date(1_759_000_000_000),
            sortOrder: 1,
            isChild: false,
            updatedAt: date(1_759_500_000_000)
        )
        func profileEdit(_ updatedAt: Date, _ change: (inout ProfileValues) -> Void) -> ProfileValues {
            var value = profile
            value.updatedAt = updatedAt
            change(&value)
            return value
        }
        let follow = SportsFollowValues(kindRaw: "team", sortOrder: 0, updatedAt: date(1_759_500_000_000))
        let server = RecordingServerValues(
            kindRaw: RecordingServerKind.lumeRecorder.rawValue,
            name: "Basement Recorder",
            baseURL: "http://recorder.example:8089",
            serverID: UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000DD02"),
            deviceID: UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000DD03"),
            token: "fictional-token-1",
            isEnabled: true,
            updatedAt: date(1_759_500_000_000)
        )
        var newerLocalServer = server
        newerLocalServer.deviceID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000DD04")
        newerLocalServer.token = "fictional-token-2"
        newerLocalServer.updatedAt = newer
        var olderRemoteServer = server
        olderRemoteServer.name = "Attic Recorder"
        olderRemoteServer.updatedAt = older

        let profiles = MergeCollection(name: "profile", merge: ProfileValues.mergeConflict, json: wire)
        let follows = MergeCollection(name: "sportsFollow", merge: SportsFollowValues.mergeConflict, json: wire)
        let servers = MergeCollection(name: "recordingServer", merge: RecordingServerValues.mergeConflict, json: wire)

        return try [
            profiles.vector(
                "newer local edit wins",
                base: profile,
                local: profileEdit(newer) { $0.name = "Harbor Room" },
                remote: profileEdit(older) { $0.sortOrder = 4 }
            ),
            profiles.vector(
                "newer remote edit wins",
                base: profile,
                local: profileEdit(older) { $0.name = "Harbor Room" },
                remote: profileEdit(newer) { $0.sortOrder = 4 }
            ),
            profiles.vector(
                "an exact updatedAt tie: remote wins",
                base: profile,
                local: profileEdit(newer) { $0.name = "Harbor Room" },
                remote: profileEdit(newer) { $0.sortOrder = 4 }
            ),
            profiles.vector(
                "isChild true from the older local side survives",
                base: profile,
                local: profileEdit(older) { $0.isChild = true },
                remote: profileEdit(newer) { $0.name = "Harbor Room" }
            ),
            profiles.vector(
                "isChild true from the older remote side survives",
                base: profile,
                local: profileEdit(newer) { $0.symbolName = "moon.fill" },
                remote: profileEdit(older) { $0.isChild = true }
            ),
            follows.vector(
                "newer local edit wins",
                base: follow,
                local: SportsFollowValues(kindRaw: "team", sortOrder: 2, updatedAt: newer),
                remote: SportsFollowValues(kindRaw: "team", sortOrder: 5, updatedAt: older)
            ),
            follows.vector(
                "an exact updatedAt tie: remote wins",
                base: follow,
                local: SportsFollowValues(kindRaw: "team", sortOrder: 2, updatedAt: newer),
                remote: SportsFollowValues(kindRaw: "team", sortOrder: 5, updatedAt: newer)
            ),
            servers.vector(
                "newer local edit wins as a whole record",
                base: server,
                local: newerLocalServer,
                remote: olderRemoteServer
            ),
            servers.vector(
                "an exact updatedAt tie: remote wins",
                base: server,
                local: newerLocalServer,
                remote: { var tie = olderRemoteServer; tie.updatedAt = newer; return tie }()
            )
        ]
    }
}

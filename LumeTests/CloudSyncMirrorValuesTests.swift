//
//  CloudSyncMirrorValuesTests.swift
//  LumeTests
//
//  Pins the owner's conflict rule for the mirror-only collections (profiles,
//  sports follows, recording servers): newest `updatedAt` wins, the remote side
//  wins an exact tie, and `UserProfile.isChild == true` always wins.
//

import Foundation
@testable import Lume
import Testing

struct ProfileValuesMergeTests {
    private let older = Date(timeIntervalSince1970: 1_800_000_000)
    private let newer = Date(timeIntervalSince1970: 1_800_000_060)

    private func profile(name: String, isChild: Bool = false, updatedAt: Date) -> ProfileValues {
        ProfileValues(
            name: name,
            symbolName: "star.fill",
            colorRaw: "teal",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sortOrder: 1,
            isChild: isChild,
            updatedAt: updatedAt
        )
    }

    @Test func `the newer local edit wins`() {
        let local = profile(name: "Marigold", updatedAt: newer)
        let cloud = profile(name: "Juniper", updatedAt: older)
        #expect(ProfileValues.mergeConflict(local: local, cloud: cloud) == local)
    }

    @Test func `the newer cloud edit wins`() {
        let local = profile(name: "Marigold", updatedAt: older)
        let cloud = profile(name: "Juniper", updatedAt: newer)
        #expect(ProfileValues.mergeConflict(local: local, cloud: cloud) == cloud)
    }

    @Test func `an exact tie goes to the cloud`() {
        let local = profile(name: "Marigold", updatedAt: newer)
        let cloud = profile(name: "Juniper", updatedAt: newer)
        #expect(ProfileValues.mergeConflict(local: local, cloud: cloud) == cloud)
    }

    @Test func `a losing local child flag still wins`() {
        let local = profile(name: "Marigold", isChild: true, updatedAt: older)
        let cloud = profile(name: "Juniper", isChild: false, updatedAt: newer)
        let merged = ProfileValues.mergeConflict(local: local, cloud: cloud)
        #expect(merged.isChild)
        #expect(merged.name == "Juniper")
        #expect(merged.updatedAt == newer)
    }

    @Test func `a losing cloud child flag still wins`() {
        let local = profile(name: "Marigold", isChild: false, updatedAt: newer)
        let cloud = profile(name: "Juniper", isChild: true, updatedAt: older)
        let merged = ProfileValues.mergeConflict(local: local, cloud: cloud)
        #expect(merged.isChild)
        #expect(merged.name == "Marigold")
        #expect(merged.updatedAt == newer)
    }

    @Test func `a child flag on a tie stays set`() {
        let local = profile(name: "Marigold", isChild: true, updatedAt: newer)
        let cloud = profile(name: "Juniper", isChild: false, updatedAt: newer)
        let merged = ProfileValues.mergeConflict(local: local, cloud: cloud)
        #expect(merged.isChild)
        #expect(merged.name == "Juniper")
    }

    @Test func `the three-way merge routes a conflict through the policy`() {
        let shadow = profile(name: "Original", updatedAt: older)
        let local = profile(name: "Marigold", isChild: true, updatedAt: older.addingTimeInterval(10))
        let cloud = profile(name: "Juniper", updatedAt: newer)
        let verdict = CloudSyncMerge.reconcile(
            local: local,
            cloud: cloud,
            shadow: shadow,
            mergeConflict: ProfileValues.mergeConflict
        )
        var expected = cloud
        expected.isChild = true
        #expect(verdict == .writeBoth(expected))
    }

    @Test func `values round-trip through Codable`() throws {
        let value = profile(name: "Marigold", isChild: true, updatedAt: newer)
        let decoded = try JSONDecoder().decode(ProfileValues.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }
}

struct SportsFollowValuesMergeTests {
    private let older = Date(timeIntervalSince1970: 1_800_000_000)
    private let newer = Date(timeIntervalSince1970: 1_800_000_001)

    @Test func `the newer local order wins`() {
        let local = SportsFollowValues(kindRaw: "team", sortOrder: 3, updatedAt: newer)
        let cloud = SportsFollowValues(kindRaw: "team", sortOrder: 0, updatedAt: older)
        #expect(SportsFollowValues.mergeConflict(local: local, cloud: cloud) == local)
    }

    @Test func `the newer cloud order wins`() {
        let local = SportsFollowValues(kindRaw: "team", sortOrder: 3, updatedAt: older)
        let cloud = SportsFollowValues(kindRaw: "team", sortOrder: 0, updatedAt: newer)
        #expect(SportsFollowValues.mergeConflict(local: local, cloud: cloud) == cloud)
    }

    @Test func `an exact tie goes to the cloud`() {
        let local = SportsFollowValues(kindRaw: "league", sortOrder: 3, updatedAt: newer)
        let cloud = SportsFollowValues(kindRaw: "team", sortOrder: 0, updatedAt: newer)
        #expect(SportsFollowValues.mergeConflict(local: local, cloud: cloud) == cloud)
    }

    @Test func `the three-way merge routes a conflict through the policy`() {
        let shadow = SportsFollowValues(kindRaw: "team", sortOrder: 1, updatedAt: older)
        let local = SportsFollowValues(kindRaw: "team", sortOrder: 2, updatedAt: newer)
        let cloud = SportsFollowValues(kindRaw: "team", sortOrder: 5, updatedAt: older.addingTimeInterval(0.5))
        let verdict = CloudSyncMerge.reconcile(
            local: local,
            cloud: cloud,
            shadow: shadow,
            mergeConflict: SportsFollowValues.mergeConflict
        )
        #expect(verdict == .writeBoth(local))
    }
}

struct RecordingServerValuesMergeTests {
    private let older = Date(timeIntervalSince1970: 1_800_000_000)
    private let newer = Date(timeIntervalSince1970: 1_800_000_300)

    private func server(name: String, token: String, updatedAt: Date) -> RecordingServerValues {
        RecordingServerValues(
            kindRaw: RecordingServerKind.lumeRecorder.rawValue,
            name: name,
            baseURL: "http://recorder.example.test:8090",
            serverID: UUID(uuidString: "6C1D2E3F-0000-4000-8000-000000000001"),
            deviceID: UUID(),
            token: token,
            isEnabled: true,
            updatedAt: updatedAt
        )
    }

    @Test func `the newer local pairing wins whole`() {
        let local = server(name: "Attic Box", token: "token-a", updatedAt: newer)
        let cloud = server(name: "Basement Box", token: "token-b", updatedAt: older)
        #expect(RecordingServerValues.mergeConflict(local: local, cloud: cloud) == local)
    }

    @Test func `the newer cloud pairing wins whole`() {
        let local = server(name: "Attic Box", token: "token-a", updatedAt: older)
        let cloud = server(name: "Basement Box", token: "token-b", updatedAt: newer)
        #expect(RecordingServerValues.mergeConflict(local: local, cloud: cloud) == cloud)
    }

    @Test func `an exact tie goes to the cloud`() {
        let local = server(name: "Attic Box", token: "token-a", updatedAt: newer)
        let cloud = server(name: "Basement Box", token: "token-b", updatedAt: newer)
        #expect(RecordingServerValues.mergeConflict(local: local, cloud: cloud) == cloud)
    }

    @Test func `the three-way merge routes a conflict through the policy`() {
        let shadow = server(name: "Attic Box", token: "token-0", updatedAt: older)
        let local = server(name: "Attic Box", token: "token-a", updatedAt: newer)
        let cloud = server(name: "Basement Box", token: "token-b", updatedAt: newer)
        let verdict = CloudSyncMerge.reconcile(
            local: local,
            cloud: cloud,
            shadow: shadow,
            mergeConflict: RecordingServerValues.mergeConflict
        )
        #expect(verdict == .writeBoth(cloud))
    }
}

@MainActor
struct CloudSyncMirrorValueMapperTests {
    @Test func `a profile maps every syncable field`() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = Date(timeIntervalSince1970: 1_800_000_000)
        let model = UserProfile(
            name: "Marigold",
            symbolName: "leaf.fill",
            colorRaw: ProfileColor.green.rawValue,
            sortOrder: 4,
            isChild: true,
            createdAt: created,
            updatedAt: updated
        )
        #expect(CloudSyncEngine.values(from: model) == ProfileValues(
            name: "Marigold",
            symbolName: "leaf.fill",
            colorRaw: ProfileColor.green.rawValue,
            createdAt: created,
            sortOrder: 4,
            isChild: true,
            updatedAt: updated
        ))
    }

    @Test func `a sports follow maps every syncable field`() {
        let updated = Date(timeIntervalSince1970: 1_800_000_000)
        let model = SyncedSportsFollow(key: "espn:soccer/xyz.1", kindRaw: "league", profileID: UUID(), sortOrder: 2, updatedAt: updated)
        #expect(CloudSyncEngine.values(from: model) == SportsFollowValues(kindRaw: "league", sortOrder: 2, updatedAt: updated))
    }

    @Test func `a recording server maps every syncable field`() {
        let updated = Date(timeIntervalSince1970: 1_800_000_000)
        let serverID = UUID()
        let deviceID = UUID()
        let model = SyncedRecordingServer(
            name: "Attic Box",
            baseURL: "http://recorder.example.test:8090",
            serverID: serverID,
            deviceID: deviceID,
            token: "token-a",
            isEnabled: false,
            updatedAt: updated
        )
        #expect(CloudSyncEngine.values(from: model) == RecordingServerValues(
            kindRaw: RecordingServerKind.lumeRecorder.rawValue,
            name: "Attic Box",
            baseURL: "http://recorder.example.test:8090",
            serverID: serverID,
            deviceID: deviceID,
            token: "token-a",
            isEnabled: false,
            updatedAt: updated
        ))
    }
}

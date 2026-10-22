//
//  SyncMirrorConsumerTests.swift
//  LumeTests
//
//  The mirror's direct readers — `ProfileManager`, `SportsFollowService` and
//  `RecordingServerConfigService` — follow an engine swap onto another mirror
//  container, and refresh when a pull posts `.lumeSyncMirrorDidChange`.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SyncMirrorConsumerTests {
    /// `cloudKitEnabled: false`: touching `CKContainer` from an un-entitled test
    /// binary crashes.
    private func makeCoordinator(_ container: ModelContainer) -> CloudSyncCoordinator {
        CloudSyncCoordinator(
            catalogContainer: container,
            cloudContainer: container,
            cloudKitContainerIdentifier: "iCloud.lume.tests.invalid",
            cloudKitEnabled: false
        )
    }

    /// A follow service scoped to `manager`'s active profile, with the region
    /// pre-follow bootstrap stamped so it seeds nothing.
    private func makeFollowService(container: ModelContainer, manager: ProfileManager) -> SportsFollowService {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        defaults.set(true, forKey: SportsFollowService.preFollowStampKey(for: manager.activeProfileID))
        let service = SportsFollowService(defaults: defaults)
        service.configure(container: container, profileManager: manager)
        return service
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 100 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func `an engine swap repoints the profile roster and the active profile`() async throws {
        let iCloudMirror = try makeProfileTestContainer()
        let lumeCloudMirror = try makeProfileTestContainer()
        iCloudMirror.mainContext.insert(UserProfile(name: "Juniper", sortOrder: 0))
        try iCloudMirror.mainContext.save()

        let coordinator = makeCoordinator(iCloudMirror)
        let manager = ProfileManager(catalogContainer: iCloudMirror, cloudContainer: iCloudMirror, coordinator: coordinator)
        #expect(manager.profiles.map(\.name) == ["Juniper"])

        lumeCloudMirror.mainContext.insert(UserProfile(id: manager.activeProfileID, name: "Marlow", sortOrder: 0))
        lumeCloudMirror.mainContext.insert(UserProfile(name: "Tamsin", sortOrder: 1))
        try lumeCloudMirror.mainContext.save()

        await coordinator.replaceEngine(mirrorContainer: lumeCloudMirror, namespace: .lumecloud, defaults: LumeCloudBackendFixture.makeDefaults())

        #expect(manager.profiles.map(\.name) == ["Marlow", "Tamsin"])
        #expect(manager.activeProfile?.name == "Marlow")
        #expect(manager.allProfiles().count == 2)
    }

    @Test func `an engine swap repoints the sports follows and recording servers`() async throws {
        let iCloudMirror = try makeProfileTestContainer()
        let lumeCloudMirror = try makeProfileTestContainer()
        let coordinator = makeCoordinator(iCloudMirror)
        let manager = ProfileManager(catalogContainer: iCloudMirror, cloudContainer: iCloudMirror, coordinator: coordinator)
        let profileID = manager.activeProfileID

        iCloudMirror.mainContext.insert(SyncedSportsFollow(key: "espn:soccer/ger.1", kindRaw: "league", profileID: profileID))
        try iCloudMirror.mainContext.save()
        let follows = makeFollowService(container: iCloudMirror, manager: manager)
        let servers = RecordingServerConfigService()
        servers.configure(container: iCloudMirror)
        coordinator.addMirrorConsumer(follows)
        coordinator.addMirrorConsumer(servers)
        #expect(follows.follows.map(\.key) == ["espn:soccer/ger.1"])
        #expect(servers.servers.isEmpty)

        lumeCloudMirror.mainContext.insert(SyncedSportsFollow(key: "espn:soccer/eng.1:7", profileID: profileID, sortOrder: 0))
        lumeCloudMirror.mainContext.insert(SyncedSportsFollow(key: "espn:soccer/esp.1:9", profileID: profileID, sortOrder: 1))
        lumeCloudMirror.mainContext.insert(SyncedRecordingServer(name: "Den Recorder", baseURL: "http://192.168.1.30:8090"))
        try lumeCloudMirror.mainContext.save()

        await coordinator.replaceEngine(mirrorContainer: lumeCloudMirror, namespace: .lumecloud, defaults: LumeCloudBackendFixture.makeDefaults())

        #expect(follows.follows.map(\.key) == ["espn:soccer/eng.1:7", "espn:soccer/esp.1:9"])
        #expect(follows.followedTeamIds == ["espn:soccer/eng.1:7", "espn:soccer/esp.1:9"])
        #expect(follows.followedLeagueIds.isEmpty)
        #expect(servers.servers.map(\.name) == ["Den Recorder"])
    }

    @Test func `a mirror change refreshes the profile roster and the sports follows`() async throws {
        let mirror = try makeProfileTestContainer()
        let coordinator = makeCoordinator(mirror)
        let manager = ProfileManager(catalogContainer: mirror, cloudContainer: mirror, coordinator: coordinator)
        let follows = makeFollowService(container: mirror, manager: manager)
        coordinator.addMirrorConsumer(follows)
        #expect(manager.profiles.isEmpty)
        #expect(follows.follows.isEmpty)

        // Rows written the way a transport applies a pull: on its own context.
        let transport = ModelContext(mirror)
        transport.insert(UserProfile(name: "Juniper"))
        transport.insert(SyncedSportsFollow(key: "espn:soccer/ita.1", kindRaw: "league", profileID: manager.activeProfileID))
        try transport.save()
        #expect(manager.profiles.isEmpty)
        #expect(follows.follows.isEmpty)

        NotificationCenter.default.post(name: .lumeSyncMirrorDidChange, object: coordinator)
        await waitUntil { !manager.profiles.isEmpty && !follows.follows.isEmpty }

        #expect(manager.profiles.map(\.name) == ["Juniper"])
        #expect(follows.follows.map(\.key) == ["espn:soccer/ita.1"])
        #expect(follows.followedLeagueIds == ["espn:soccer/ita.1"])
    }

    @Test func `swapping back repoints onto the original mirror`() async throws {
        let first = try makeProfileTestContainer()
        let second = try makeProfileTestContainer()
        second.mainContext.insert(UserProfile(name: "Tamsin"))
        try second.mainContext.save()
        let coordinator = makeCoordinator(first)
        let manager = ProfileManager(catalogContainer: first, cloudContainer: first, coordinator: coordinator)

        await coordinator.replaceEngine(mirrorContainer: second, namespace: .lumecloud, defaults: LumeCloudBackendFixture.makeDefaults())
        #expect(manager.profiles.map(\.name) == ["Tamsin"])

        await coordinator.replaceEngine(mirrorContainer: first, namespace: .icloud, defaults: LumeCloudBackendFixture.makeDefaults())
        #expect(manager.profiles.isEmpty)
    }
}

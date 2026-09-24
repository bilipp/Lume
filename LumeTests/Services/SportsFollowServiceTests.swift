//
//  SportsFollowServiceTests.swift
//  LumeTests
//
//  Covers `SportsFollowService` over the cloud container's main context: a
//  follow persists and reloads, order survives a reload and a reorder, follows
//  are isolated per profile, and the per-region pre-follow bootstrap runs exactly
//  once per profile.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SportsFollowServiceTests {
    /// A private defaults suite keeps the pre-follow stamps (and any other flag)
    /// out of the shared host defaults, so bootstrap is controllable per test.
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "sports.follow.test.\(UUID().uuidString)")!
    }

    /// A service scoped to `profile`, with its pre-follow bootstrap pre-stamped so
    /// it doesn't seed region defaults on the first reload.
    private func makeService(
        container: ModelContainer,
        defaults: UserDefaults,
        profile: UUID,
        suppressBootstrap: Bool = true
    ) -> SportsFollowService {
        if suppressBootstrap {
            defaults.set(true, forKey: SportsFollowService.preFollowStampKey(for: profile))
        }
        let service = SportsFollowService(defaults: defaults)
        service.configure(container: container)
        return service
    }

    @Test func `follow persists and reloads from a fresh service`() throws {
        let container = try makeProfileTestContainer()
        let defaults = freshDefaults()
        let profile = UUID()
        let saved = ActiveProfileStore.current
        ActiveProfileStore.current = profile
        defer { ActiveProfileStore.current = saved }

        let service = makeService(container: container, defaults: defaults, profile: profile)
        service.follow("espn:soccer/ger.1", kind: .league)

        #expect(service.isFollowing("espn:soccer/ger.1"))
        #expect(service.followedLeagueIds == ["espn:soccer/ger.1"])
        #expect(service.follows.count == 1)

        let reloaded = SportsFollowService(defaults: defaults)
        reloaded.configure(container: container)
        #expect(reloaded.isFollowing("espn:soccer/ger.1"))
        #expect(reloaded.follows.count == 1)
    }

    @Test func `order persists across reload and reorder`() throws {
        let container = try makeProfileTestContainer()
        let defaults = freshDefaults()
        let profile = UUID()
        let saved = ActiveProfileStore.current
        ActiveProfileStore.current = profile
        defer { ActiveProfileStore.current = saved }

        let service = makeService(container: container, defaults: defaults, profile: profile)
        service.follow("espn:soccer/ger.1", kind: .league)
        service.follow("espn:soccer/eng.1", kind: .league)
        service.follow("espn:soccer/esp.1", kind: .league)
        #expect(service.followedLeagueIds == ["espn:soccer/ger.1", "espn:soccer/eng.1", "espn:soccer/esp.1"])

        // Move the last to the front.
        service.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(service.followedLeagueIds == ["espn:soccer/esp.1", "espn:soccer/ger.1", "espn:soccer/eng.1"])

        let reloaded = SportsFollowService(defaults: defaults)
        reloaded.configure(container: container)
        #expect(reloaded.followedLeagueIds == ["espn:soccer/esp.1", "espn:soccer/ger.1", "espn:soccer/eng.1"])
    }

    @Test func `teams and leagues are separated in the source`() throws {
        let container = try makeProfileTestContainer()
        let defaults = freshDefaults()
        let profile = UUID()
        let saved = ActiveProfileStore.current
        ActiveProfileStore.current = profile
        defer { ActiveProfileStore.current = saved }

        let service = makeService(container: container, defaults: defaults, profile: profile)
        service.follow("espn:soccer/ger.1", kind: .league)
        service.follow("espn:soccer/ger.1:132", kind: .team)

        #expect(service.followedLeagueIds == ["espn:soccer/ger.1"])
        #expect(service.followedTeamIds == ["espn:soccer/ger.1:132"])

        service.unfollow("espn:soccer/ger.1")
        #expect(!service.isFollowing("espn:soccer/ger.1"))
        #expect(service.followedLeagueIds.isEmpty)
        #expect(service.followedTeamIds == ["espn:soccer/ger.1:132"])
    }

    @Test func `follows are isolated per profile`() throws {
        let container = try makeProfileTestContainer()
        let defaults = freshDefaults()
        let profileA = UUID()
        let profileB = UUID()
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }

        ActiveProfileStore.current = profileA
        let serviceA = makeService(container: container, defaults: defaults, profile: profileA)
        serviceA.follow("espn:soccer/ger.1", kind: .league)

        ActiveProfileStore.current = profileB
        let serviceB = makeService(container: container, defaults: defaults, profile: profileB)
        #expect(serviceB.follows.isEmpty)
        serviceB.follow("espn:soccer/eng.1", kind: .league)
        #expect(serviceB.followedLeagueIds == ["espn:soccer/eng.1"])

        // Switching back shows only profile A's follow.
        ActiveProfileStore.current = profileA
        serviceA.reload()
        #expect(serviceA.followedLeagueIds == ["espn:soccer/ger.1"])
    }

    @Test func `pre-follow bootstrap runs exactly once`() throws {
        let container = try makeProfileTestContainer()
        let defaults = freshDefaults()
        let profile = UUID()
        let saved = ActiveProfileStore.current
        ActiveProfileStore.current = profile
        defer { ActiveProfileStore.current = saved }

        let expected = SportsCatalog.regionPreFollows(for: Locale.current.region)
        #expect(!expected.isEmpty)

        // No stamp: bootstrap should seed the region defaults.
        let service = SportsFollowService(defaults: defaults)
        service.configure(container: container)
        #expect(service.followedLeagueIds == expected)
        #expect(defaults.bool(forKey: SportsFollowService.preFollowStampKey(for: profile)))

        // Remove them all, reload — bootstrap must not re-seed.
        for key in expected {
            service.unfollow(key)
        }
        #expect(service.follows.isEmpty)
        service.reload()
        #expect(service.follows.isEmpty)

        // A brand-new service over the same store/defaults also must not re-seed.
        let reloaded = SportsFollowService(defaults: defaults)
        reloaded.configure(container: container)
        #expect(reloaded.follows.isEmpty)
    }
}

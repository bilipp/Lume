import Foundation
@testable import Lume
import SwiftData
import Testing

struct OnboardingUsageProbeTests {
    /// `UserContentState` and `UserProfile` live in the CloudKit-mirrored store;
    /// the two-configuration container routes them there by model type.
    private func makeContext() throws -> ModelContext {
        let container = try makeProfileTestContainer()
        return ModelContext(container)
    }

    @Test func `an empty store reads as no prior usage`() throws {
        let context = try makeContext()
        #expect(!OnboardingUsageProbe.hasPriorUsage(in: context))
    }

    @Test func `watch progress counts as prior usage`() throws {
        let context = try makeContext()
        context.insert(UserContentState(contentId: "movie-1", kind: .movie, watchProgress: 0.4))
        try context.save()
        #expect(OnboardingUsageProbe.hasPriorUsage(in: context))
    }

    @Test func `a watched flag counts as prior usage`() throws {
        let context = try makeContext()
        context.insert(UserContentState(contentId: "movie-2", kind: .movie, isWatched: true))
        try context.save()
        #expect(OnboardingUsageProbe.hasPriorUsage(in: context))
    }

    @Test func `a last watched date counts as prior usage`() throws {
        let context = try makeContext()
        context.insert(UserContentState(contentId: "live-1", kind: .live, lastWatchedDate: Date()))
        try context.save()
        #expect(OnboardingUsageProbe.hasPriorUsage(in: context))
    }

    @Test func `a state row with no watch history is not prior usage`() throws {
        let context = try makeContext()
        context.insert(UserContentState(contentId: "movie-3", kind: .movie, isFavorite: true))
        try context.save()
        #expect(!OnboardingUsageProbe.hasPriorUsage(in: context))
    }

    @Test func `a user created profile counts as prior usage`() throws {
        let context = try makeContext()
        context.insert(UserProfile(name: "Kids", isChild: true))
        try context.save()
        #expect(OnboardingUsageProbe.hasPriorUsage(in: context))
    }

    @Test func `the auto created default profile alone is not prior usage`() throws {
        let context = try makeContext()
        context.insert(UserProfile(id: UserProfile.defaultProfileID, name: "Profile 1"))
        try context.save()
        #expect(!OnboardingUsageProbe.hasPriorUsage(in: context))
    }
}

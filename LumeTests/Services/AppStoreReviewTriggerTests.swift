import Foundation
@testable import Lume
import Testing

struct AppStoreReviewTriggerTests {
    /// A throwaway, empty `UserDefaults` domain so the policy never reads or
    /// mutates the shared standard suite.
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AppStoreReviewTriggerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func `does not ask before the completion threshold`() throws {
        let defaults = try makeDefaults()
        for _ in 1 ..< AppStoreReviewTrigger.completionThreshold {
            #expect(AppStoreReviewTrigger.registerSignificantEvent(defaults: defaults, currentVersion: "1.0") == false)
        }
    }

    @Test func `asks once the threshold is reached`() throws {
        let defaults = try makeDefaults()
        var eligible = false
        for _ in 0 ..< AppStoreReviewTrigger.completionThreshold {
            eligible = AppStoreReviewTrigger.registerSignificantEvent(defaults: defaults, currentVersion: "1.0")
        }
        #expect(eligible)
    }

    @Test func `does not ask twice on the same version`() throws {
        let defaults = try makeDefaults()
        for _ in 0 ..< AppStoreReviewTrigger.completionThreshold {
            _ = AppStoreReviewTrigger.registerSignificantEvent(defaults: defaults, currentVersion: "1.0")
        }
        AppStoreReviewTrigger.markPromptShown(defaults: defaults, currentVersion: "1.0")

        // After showing, the counter resets and the same version stays blocked.
        for _ in 0 ..< AppStoreReviewTrigger.completionThreshold {
            #expect(AppStoreReviewTrigger.registerSignificantEvent(defaults: defaults, currentVersion: "1.0") == false)
        }
    }

    @Test func `asks again after an app update`() throws {
        let defaults = try makeDefaults()
        for _ in 0 ..< AppStoreReviewTrigger.completionThreshold {
            _ = AppStoreReviewTrigger.registerSignificantEvent(defaults: defaults, currentVersion: "1.0")
        }
        AppStoreReviewTrigger.markPromptShown(defaults: defaults, currentVersion: "1.0")

        // markPromptShown reset the counter, so a later version must accumulate
        // its own completions before the prompt becomes eligible again.
        var eligible = false
        for _ in 0 ..< AppStoreReviewTrigger.completionThreshold {
            eligible = AppStoreReviewTrigger.registerSignificantEvent(defaults: defaults, currentVersion: "1.1")
        }
        #expect(eligible)
    }
}

@testable import Lume
import Testing

struct OnboardingSettingsTests {
    @Test func `keys and defaults are stable`() {
        #expect(OnboardingSettings.seenVersionKey == "onboarding.seenVersion.v1")
        #expect(OnboardingSettings.seenVersionDefault == 0)
        #expect(OnboardingSettings.currentVersion == 1)
    }

    @Test func `fresh install needs onboarding`() {
        #expect(OnboardingSettings.needsOnboarding(
            seenVersion: OnboardingSettings.seenVersionDefault,
            isUITesting: false,
            hasPriorUsage: false
        ))
    }

    @Test func `ui testing suppresses onboarding`() {
        #expect(!OnboardingSettings.needsOnboarding(
            seenVersion: 0,
            isUITesting: true,
            hasPriorUsage: false
        ))
    }

    @Test func `prior usage suppresses onboarding`() {
        #expect(!OnboardingSettings.needsOnboarding(
            seenVersion: 0,
            isUITesting: false,
            hasPriorUsage: true
        ))
    }

    @Test func `already seen current version does not repeat`() {
        #expect(!OnboardingSettings.needsOnboarding(
            seenVersion: OnboardingSettings.currentVersion,
            isUITesting: false,
            hasPriorUsage: false
        ))
    }

    @Test func `a newer stored version never re-shows`() {
        #expect(!OnboardingSettings.needsOnboarding(
            seenVersion: OnboardingSettings.currentVersion + 1,
            isUITesting: false,
            hasPriorUsage: false
        ))
    }

    @Test func `an older stored version re-shows a rewritten guide`() {
        #expect(OnboardingSettings.needsOnboarding(
            seenVersion: OnboardingSettings.currentVersion - 1,
            isUITesting: false,
            hasPriorUsage: false
        ))
    }
}

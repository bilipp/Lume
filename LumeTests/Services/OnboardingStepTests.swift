import Foundation
@testable import Lume
import Testing

struct OnboardingStepTests {
    /// New keys this step list introduces. The whole onboarding feature is
    /// capped at 40 new keys.
    private static let addedKeys = [
        "Lume is a player",
        "Bring your own service",
        "Your library, organized",
        "It ships with no channels, streams, or content of its own — it gives what you already pay for "
            + "a native home on every Apple device.",
        "Sign in with your own Xtream Codes credentials or point Lume at an M3U playlist. "
            + "The catalog is indexed on device, so browsing stays instant.",
        "Movies and Series arrive sorted by category and enriched with artwork, cast, trailers and ratings. "
            + "Your progress follows you across your devices.",
        "Flip through channels with a full TV Guide, see what is on now, "
            + "and jump straight back to the last thing you watched.",
        "Find any channel, movie or episode across every playlist you have added, as you type.",
        "Press Play/Pause on the Home screen to change playlist or profile without losing your place.",
        "Watch up to four live channels side by side on the big screen."
    ]

    /// Surface keys the guide reuses verbatim rather than adding near-duplicates.
    private static let reusedKeys = [
        "Live TV",
        "Search",
        "Quick Switch",
        "Multi-View"
    ]

    @Test func `literals resolve to a non empty string`() {
        for key in Self.addedKeys + Self.reusedKeys {
            let resolved = String(localized: String.LocalizationValue(key))
            #expect(!resolved.isEmpty, "\(key) resolved to an empty string")
        }
    }

    @Test func `every case resolves to a non empty title and subtitle`() {
        for step in OnboardingStep.allCases {
            #expect(!String(localized: step.title).isEmpty, "\(step.rawValue) has an empty title")
            #expect(!String(localized: step.subtitle).isEmpty, "\(step.rawValue) has an empty subtitle")
        }
    }

    @Test func `every case names an SF Symbol`() {
        for step in OnboardingStep.allCases {
            #expect(!step.systemImage.isEmpty, "\(step.rawValue) has no symbol")
        }
    }

    @Test func `id is the raw value`() {
        for step in OnboardingStep.allCases {
            #expect(step.id == step.rawValue)
        }
    }

    @Test func `steps open with what Lume is and how to connect`() {
        #expect(OnboardingStep.steps.prefix(2) == [.whatIsLume, .addProvider])
    }

    @Test func `steps are unique and ordered as declared`() {
        let steps = OnboardingStep.steps
        #expect(Set(steps).count == steps.count)
        #expect(steps == OnboardingStep.allCases.filter(steps.contains))
    }

    @Test func `platform steps list only surfaces this platform has`() {
        let steps = Set(OnboardingStep.steps)
        #if os(tvOS)
            #expect(steps == Set(OnboardingStep.allCases))
        #else
            #expect(!steps.contains(.quickSwitch))
            #expect(!steps.contains(.multiView))
            #expect(steps.contains(.search))
        #endif
    }
}

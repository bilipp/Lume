//
//  SettingsView+Onboarding.swift
//  Lume
//
//  The "How Lume Works" re-open row (iOS / macOS / visionOS), split out of
//  SettingsView to keep that type's body within the file-size limit.
//
//  A `NavigationLink` push rather than a sheet, following `CreditsView`: Settings
//  is itself a sheet on macOS and visionOS, and a sheet on a sheet loses the
//  Settings chrome behind it.
//
//  Re-reading the guide never touches `OnboardingSettings.seenVersionKey` — the
//  flag records that the first-launch pass happened, not how often it was read.
//

import SwiftUI

extension SettingsView {
    #if !os(tvOS)
        /// The Support-area row that replays the first-launch guide.
        var onboardingSection: some View {
            Section {
                NavigationLink {
                    OnboardingGuideDestination()
                } label: {
                    Label {
                        Text(
                            "How Lume Works",
                            comment: "Title of the first-launch guide and of the Settings row that re-opens it"
                        )
                    } icon: {
                        Image(systemName: "sparkles.tv")
                    }
                }
            }
        }
    #endif
}

#if !os(tvOS)
    /// Wraps the guide so its final button can pop this push. `OnboardingView`
    /// takes an explicit `onFinish` and never reads `@Environment(\.dismiss)`
    /// itself: it is also used as root content on macOS, where `dismiss()` closes
    /// the app's only window. Here the dismiss belongs to the pushed destination,
    /// so it pops — while `SettingsView`'s own `dismiss` would close Settings.
    private struct OnboardingGuideDestination: View {
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            OnboardingView(isModal: false) { dismiss() }
        }
    }
#endif

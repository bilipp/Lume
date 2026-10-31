//
//  SiriTipSection.swift
//  Lume
//

#if os(iOS)
    import AppIntents
    import SwiftUI

    /// Points Pro users at the Siri phrases. Siri is Pro-only, so a free plan
    /// sees nothing here.
    struct SiriTipSection: View {
        @State private var premium = PremiumManager.shared

        var body: some View {
            if premium.isPremium {
                Section {
                    SiriTipView(intent: ResumeWatchingIntent())
                    ShortcutsLink()
                } header: {
                    Text("Siri")
                } footer: {
                    Text("Ask Siri to play a channel, movie or series by name, or to continue watching.")
                }
            }
        }
    }
#endif

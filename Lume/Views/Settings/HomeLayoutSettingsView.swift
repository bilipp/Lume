#if !os(tvOS)

    import SwiftUI

    /// Home screen layout settings (iOS / macOS): switch each Home row on or off
    /// and drag to reorder them. Each row still only appears on Home when it has
    /// something to show. See `HomeLayoutSettings`.
    struct HomeLayoutSettingsView: View {
        /// "For You" is the opt-in recommendations row; its toggle writes the same
        /// flag that gates the recommendation recompute on Home.
        @AppStorage(RecommendationSettings.enabledKey) private var recommendationsEnabled = RecommendationSettings.enabledDefault
        @AppStorage(HomeLayoutSettings.sectionOrderKey) private var sectionOrderRaw = ""
        @AppStorage(HomeLayoutSettings.disabledSectionsKey) private var disabledSectionsRaw = ""
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false

        private var sections: [HomeSection] {
            HomeLayoutSettings.resolve(orderRaw: sectionOrderRaw)
        }

        var body: some View {
            List {
                Section {
                    ForEach(sections) { section in
                        Toggle(isOn: enabledBinding(for: section)) {
                            rowLabel(for: section)
                        }
                    }
                    .onMove(perform: move)
                } header: {
                    Text("Sections")
                } footer: {
                    Text("Turn sections on or off and reorder them. Each appears on Home only when it has something to show. \"For You\" is built on-device from your library and what you watch.")
                }
            }
            .platformNavigationTitle("Home")
            #if os(iOS)
                // Keep the list permanently in edit mode so the rows are always
                // draggable — no Edit button to enter reorder mode first (matches
                // the Player Engines list). Toggles stay interactive in edit mode.
                .environment(\.editMode, .constant(.active))
            #endif
                .paywall(isPresented: $showPaywall, highlight: .recommendations)
        }

        @ViewBuilder
        private func rowLabel(for section: HomeSection) -> some View {
            // "For You" is a Lume Pro feature: badge it with a crown for free users
            // (Sideload/owned builds are always premium, so the crown never shows).
            if section == .forYou, !premium.isPremium {
                Label {
                    HStack(spacing: 6) {
                        Text(section.title)
                        Image(systemName: "crown.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                } icon: {
                    Image(systemName: section.systemImage)
                }
            } else {
                Label(section.title, systemImage: section.systemImage)
            }
        }

        /// On/off binding for a section. "For You" maps to the recommendations
        /// flag and is gated behind Lume Pro — a free user turning it on gets the
        /// paywall instead. Every other section is tracked by `HomeLayoutSettings`'
        /// disabled set (absent ⇒ enabled).
        private func enabledBinding(for section: HomeSection) -> Binding<Bool> {
            if section == .forYou {
                return Binding(
                    get: { recommendationsEnabled },
                    set: { isOn in
                        if isOn, !premium.isPremium {
                            // Don't enable; surface the paywall. The toggle snaps
                            // back to off because the getter still returns false.
                            showPaywall = true
                            return
                        }
                        recommendationsEnabled = isOn
                    }
                )
            }
            return Binding(
                get: { HomeLayoutSettings.isEnabled(section, disabledRaw: disabledSectionsRaw) },
                set: { isOn in
                    var disabled = HomeLayoutSettings.decodeDisabled(disabledSectionsRaw)
                    if isOn { disabled.remove(section) } else { disabled.insert(section) }
                    disabledSectionsRaw = HomeLayoutSettings.encodeDisabled(disabled)
                }
            )
        }

        private func move(from offsets: IndexSet, to destination: Int) {
            var list = sections
            list.move(fromOffsets: offsets, toOffset: destination)
            sectionOrderRaw = HomeLayoutSettings.encode(HomeLayoutSettings.normalized(list))
        }
    }

    #Preview {
        NavigationStack {
            HomeLayoutSettingsView()
        }
    }

#endif

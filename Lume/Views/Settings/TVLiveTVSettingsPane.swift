//
//  TVLiveTVSettingsPane.swift
//  Lume
//
//  The tvOS Live TV settings pane: the Live TV tab's layout (Guide / List)
//  and Guide Preview, whether Favorites and Recently Watched lead the rails,
//  then the recording server — a drill-in SettingsView
//  swaps in place, like Player's Engines — the recordings library and whether
//  the Live TV rail lists it. Channel Surfing stays under Player: it is how
//  the player reads the remote, not how the tab looks.
//

#if os(tvOS)

    import SwiftUI

    struct TVLiveTVSettingsPane: View {
        /// Owned by SettingsView, which clears it when focus returns to the
        /// sidebar, like its other drill-ins.
        @Binding var showingRecordingServer: Bool
        /// SettingsView's paywall, so the pane never stacks a second one.
        let presentPaywall: (PremiumFeature) -> Void

        @AppStorage(LiveTVLayoutMode.storageKey)
        private var layoutModeRaw = LiveTVLayoutMode.defaultMode.rawValue
        @AppStorage(PlayerSettings.tvGuidePreviewModeKey)
        private var guidePreviewModeRaw = PlayerSettings.tvGuidePreviewModeDefault.rawValue
        @AppStorage(LiveTVRailSettings.showsFavoritesKey)
        private var showsFavorites = LiveTVRailSettings.showsFavoritesDefault
        @AppStorage(LiveTVRailSettings.showsRecentlyWatchedKey)
        private var showsRecentlyWatched = LiveTVRailSettings.showsRecentlyWatchedDefault
        @AppStorage(RecordingServerSetup.showsRecordingsInLiveTVRailKey)
        private var showsRecordingsInRail = RecordingServerSetup.showsRecordingsInLiveTVRailDefault
        @State private var premium = PremiumManager.shared
        @State private var configService = RecordingServerConfigService.shared
        @State private var store = RecordingServerStore.shared
        @State private var showingRecordings = false
        @FocusState private var focus: Row?

        private enum Row: Hashable {
            case layout, guidePreview, favorites, recentlyWatched, recordingServer, recordings, rail
        }

        private var access: RecordingSettingsAccess {
            RecordingSettingsAccess(
                isUnlocked: store.isUnlocked,
                hasServers: !configService.servers.isEmpty,
                isPaired: store.isPaired
            )
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 28) {
                layoutSection
                categoriesSection
                recordingSection
            }
            // Entry from the sidebar lands on the first row, not the one
            // nearest the sidebar row it came from.
            .defaultFocus($focus, .layout, priority: .userInitiated)
            .fullScreenCover(isPresented: $showingRecordings) {
                recordingsLibrary
            }
        }

        // MARK: - Layout

        private var layoutSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Layout")

                TVOptionCycleRow(
                    title: "Live TV Layout",
                    valueLabel: LiveTVLayoutMode(storedValue: layoutModeRaw).displayName
                ) {
                    layoutModeRaw = PlayerOptionCycle.next(layoutModeRaw, in: LiveTVLayoutMode.self)
                }
                .focused($focus, equals: .layout)

                footer("How the Live TV tab shows channels: Guide lays them out on a programme timeline, List as a plain channel list.")

                // Every choice is open to everyone: the layout is free, only
                // the video needs Lume Pro (the crown says so).
                TVOptionCycleRow(
                    title: "Guide Preview",
                    valueLabel: GuidePreviewMode(storedValue: guidePreviewModeRaw).displayName,
                    showsPremiumBadge: !premium.isPremium
                ) {
                    guidePreviewModeRaw = PlayerOptionCycle.next(guidePreviewModeRaw, in: GuidePreviewMode.self)
                }
                .focused($focus, equals: .guidePreview)

                footer("Small and Large play the focused channel muted and use a provider connection while you browse. Info Only shows it without video; Off gives the Guide the full height.")
            }
        }

        // MARK: - Categories

        private var categoriesSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Categories")

                TVOptionToggleRow(title: "Favorites", isOn: $showsFavorites)
                    .focused($focus, equals: .favorites)

                TVOptionToggleRow(title: "Recently Watched", isOn: $showsRecentlyWatched)
                    .focused($focus, equals: .recentlyWatched)

                footer("Shows these collections above your categories in Live TV.")
            }
        }

        // MARK: - Recording

        private var recordingSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Recordings")

                recordingServerRow
                    .focused($focus, equals: .recordingServer)

                if access.showsRecordingsRow {
                    recordingsRow
                        .focused($focus, equals: .recordings)

                    TVOptionToggleRow(title: "Show in Live TV Sidebar", isOn: $showsRecordingsInRail)
                        .focused($focus, equals: .rail)

                    footer("Lists Recordings in the Live TV sidebar, below Favorites and Recently Watched.")
                }
            }
        }

        /// Free with nothing paired, the row opens the paywall rather than a
        /// pane that would only repeat it. A lapsed subscriber's paired server
        /// stays reachable, crown and all, so it can be removed.
        private var recordingServerRow: some View {
            Button {
                if access.serverRowOpensPaywall {
                    presentPaywall(.recordingServer)
                } else {
                    showingRecordingServer = true
                }
            } label: {
                HStack(spacing: 16) {
                    Text("Recording Server")
                    if access.serverRowShowsBadge {
                        PremiumBadge()
                    }
                    Spacer(minLength: 0)
                    if let value = recordingServerValue {
                        value
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }

        /// The paired server's name, "Not paired" once pairing is open to the
        /// user, and nothing on the locked row (the crown says enough).
        private var recordingServerValue: Text? {
            if let server = configService.activeServer, !server.name.isEmpty {
                return Text(verbatim: server.name)
            }
            return access.serverRowOpensPaywall ? nil : Text("Not paired")
        }

        /// The same rule as the Live TV rail's Recordings entry: without Lume
        /// Pro it leads with the plain crown and opens the paywall.
        private var recordingsRow: some View {
            Button {
                if access.recordingsRowOpensPaywall {
                    presentPaywall(.recordingServer)
                } else {
                    showingRecordings = true
                }
            } label: {
                HStack(spacing: 16) {
                    if access.recordingsRowOpensPaywall {
                        Image(systemName: "crown")
                            .font(.system(size: 22, weight: .medium))
                    }
                    Text("Recordings")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }

        /// The library full screen: focus lands on its first card (or holds
        /// in place when it is empty), Menu dismisses it, and focus returns to
        /// the Recordings row.
        private var recordingsLibrary: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recordings")
                    .font(.system(size: TVSettingsMetrics.titleFontSize, weight: .bold))
                    .padding(.horizontal, TVRecordingsMetrics.bandInset)
                TVRecordingsView(holdsFocusWhenEmpty: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 40)
            .tvSettingsBackground()
        }

        private func footer(_ text: LocalizedStringKey) -> some View {
            Text(text)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 6)
        }
    }

#endif

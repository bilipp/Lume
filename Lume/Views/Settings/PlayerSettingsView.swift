//
//  PlayerSettingsView.swift
//  Lume
//
//  The iOS / macOS / visionOS Player page — everyday playback options first,
//  then audio languages, OpenSubtitles, the stream-information caption, and under Advanced the
//  engine priority and the external-player hand-off — plus the Engines page
//  behind it. tvOS builds its own pane in SettingsView+TVPlayer.
//

#if !os(tvOS)

    import SwiftUI

    struct PlayerSettingsView: View {
        @AppStorage(PlayerSettings.Playback.autoPlayNextKey)
        private var autoPlayNext = PlayerSettings.Playback.autoPlayNextDefault
        @AppStorage(PlayerSettings.Playback.showSkipIntroButtonKey)
        private var showSkipIntroButton = PlayerSettings.Playback.showSkipIntroButtonDefault
        @AppStorage(PlayerSettings.StreamInfo.enabledKey)
        private var streamInfoEnabled = PlayerSettings.StreamInfo.enabledDefault
        @AppStorage(PlayerSettings.StreamInfo.detailLevelKey)
        private var streamInfoDetailLevelRaw = PlayerSettings.StreamInfo.detailLevelDefault.rawValue
        @AppStorage(PlayerSettings.externalPlayerKey) private var externalPlayerRaw: String = ""
        @AppStorage(PlayerSettings.externalPlayerScopeKey)
        private var externalPlayerScopeRaw: String = ExternalPlayerScope.default.rawValue
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        @State private var openSubtitles = OpenSubtitlesService.shared

        /// The stored detail level, resolved through the same fallback the player
        /// uses so a stale or unknown raw value reads as the platform default.
        private var streamInfoDetailLevel: StreamInfoDetailLevel {
            StreamInfoDetailLevel(rawValue: streamInfoDetailLevelRaw) ?? PlayerSettings.StreamInfo.detailLevelDefault
        }

        var body: some View {
            List {
                Section {
                    premiumToggle("Autoplay Next Episode", isOn: $autoPlayNext)
                    premiumToggle("Show Skip Intro Button", isOn: $showSkipIntroButton)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Automatically start the next episode when one finishes.")
                }

                Section {
                    NavigationLink("Audio Languages") { PreferredLanguageListView() }
                } header: {
                    Text("Languages")
                }

                if openSubtitles.isConfigured {
                    Section {
                        NavigationLink {
                            OpenSubtitlesIntegrationView()
                        } label: {
                            HStack {
                                Text(verbatim: "OpenSubtitles")
                                Spacer()
                                if let username = openSubtitles.username {
                                    Text(verbatim: username)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Subtitles")
                    } footer: {
                        Text("Download subtitles for anything that ships without them.")
                    }
                }

                // Free for everyone — deliberately not premium-gated like the
                // Playback toggles above.
                Section {
                    Toggle("Show Stream Information", isOn: $streamInfoEnabled)

                    if streamInfoEnabled {
                        Picker("Detail Level", selection: $streamInfoDetailLevelRaw) {
                            ForEach(StreamInfoDetailLevel.allCases) { level in
                                Text(level.title).tag(level.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text("Stream Information")
                } footer: {
                    Text(streamInfoDetailLevel.footer)
                }

                advancedSection
            }
            .platformNavigationTitle("Player")
            .paywall(isPresented: $showPaywall, highlight: .playbackControls)
        }

        private var advancedSection: some View {
            Section {
                NavigationLink("Engines") { PlayerEnginesView() }

                Picker("External Player", selection: $externalPlayerRaw) {
                    Text("Off").tag("")
                    ForEach(ExternalPlayer.allCases) { player in
                        Text(player.displayName).tag(player.rawValue)
                    }
                }
                .pickerStyle(.menu)

                // Only meaningful once a player is selected — some players
                // (Infuse, for one) handle VOD but not live streams.
                if ExternalPlayer(rawValue: externalPlayerRaw) != nil {
                    Picker("Use For", selection: $externalPlayerScopeRaw) {
                        ForEach(ExternalPlayerScope.allCases) { scope in
                            Text(scope.displayName).tag(scope.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("Advanced")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Lume plays each stream with your preferred engine and falls back to the next if it can't be played.")
                    // swiftlint:disable:next line_length
                    Text("Streams open in the selected external app instead of Lume's player, when it is installed. Some apps — Infuse among them — play movies and series but no live channels, so you can limit the hand-off to one or the other.")
                }
            }
        }

        /// A Lume Pro switch: free users see it off with a crown, and
        /// flipping it opens the paywall instead of changing the setting.
        private func premiumToggle(_ title: LocalizedStringKey, isOn value: Binding<Bool>) -> some View {
            Toggle(isOn: Binding(
                get: { premium.isPremium && value.wrappedValue },
                set: { newValue in
                    if premium.isPremium {
                        value.wrappedValue = newValue
                    } else {
                        showPaywall = true
                    }
                }
            )) {
                HStack(spacing: 6) {
                    Text(title)
                    if !premium.isPremium {
                        PremiumBadge()
                    }
                }
            }
        }
    }

    // MARK: - Engines

    /// The engine priority list (the first engine is the primary; Lume falls back
    /// down the list whenever an engine can't start a stream — see
    /// `PlayerEnginePriority`), and each engine's options below it.
    struct PlayerEnginesView: View {
        /// Legacy single-engine key, kept in sync with the primary engine and used
        /// as the migration seed for the priority list.
        @AppStorage(PlayerSettings.engineKey) private var engineRaw = PlayerEngineKind.defaultValue.rawValue
        @AppStorage(PlayerSettings.enginePriorityKey) private var enginePriorityRaw = ""
        @State private var optionsEngine: PlayerEngineKind?

        private var engines: [PlayerEngineKind] {
            PlayerEnginePriority.resolve(priorityRaw: enginePriorityRaw, legacyEngineRaw: engineRaw)
        }

        /// AVPlayer has no configurable options, so it gets no row.
        private let configurableEngines: [PlayerEngineKind] = [.ksPlayer, .vlcKit, .lumeEngine]

        var body: some View {
            List {
                Section {
                    ForEach(engines) { kind in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(kind.displayName)
                                if kind == engines.first {
                                    Text("Primary")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text(kind.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove(perform: move)
                } header: {
                    Text("Priority")
                } footer: {
                    Text("Lume plays each stream with the first engine and automatically falls back to the next if it can't be played. Drag to reorder.")
                }

                Section {
                    ForEach(configurableEngines) { kind in
                        // A borderless button rather than a NavigationLink: the
                        // list is held in edit mode for the drag handles above,
                        // and an editing list's rows take no taps — its
                        // controls still do.
                        Button {
                            optionsEngine = kind
                        } label: {
                            HStack {
                                Text(kind.displayName)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .tint(.primary)
                    }
                } header: {
                    Text("Options")
                } footer: {
                    Text("AVPlayer has no configurable options.")
                }
            }
            .platformNavigationTitle("Engines")
            .navigationDestination(item: $optionsEngine) { kind in
                switch kind {
                case .ksPlayer: KSEngineSettingsScreen()
                case .vlcKit: VLCEngineSettingsScreen()
                case .lumeEngine: LumeEngineSettingsScreen()
                case .avPlayer: EmptyView()
                }
            }
            .alwaysEditing()
        }

        private func move(from offsets: IndexSet, to destination: Int) {
            var list = engines
            list.move(fromOffsets: offsets, toOffset: destination)
            let normalized = PlayerEnginePriority.normalized(list)
            enginePriorityRaw = PlayerEnginePriority.encode(normalized)
            engineRaw = normalized.first?.rawValue ?? PlayerEngineKind.defaultValue.rawValue
        }
    }

    private extension View {
        /// Keeps the list permanently in edit mode so the engine rows are always
        /// draggable — no Edit button to enter reorder mode first. macOS has no
        /// `EditMode`; its lists make `onMove` rows draggable on their own.
        func alwaysEditing() -> some View {
            #if os(iOS) || os(visionOS)
                environment(\.editMode, .constant(.active))
            #else
                self
            #endif
        }
    }

    #Preview {
        NavigationStack {
            PlayerSettingsView()
        }
    }

#endif

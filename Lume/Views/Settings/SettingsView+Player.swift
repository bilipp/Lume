//
//  SettingsView+Player.swift
//  Lume
//
//  The iOS / macOS / visionOS Player settings groups: the engine priority and
//  per-engine options links, the preferred audio language row, and the external
//  player hand-off. Split out of SettingsView to keep that file within the
//  project's line-count cap; tvOS builds its own pane in SettingsView+TVPlayer.
//

#if !os(tvOS)

    import SwiftUI

    extension SettingsView {
        /// Not `private`: composed by `standardBody` in SettingsView.swift.
        var playerSection: some View {
            Section {
                NavigationLink {
                    PlayerEnginePriorityView()
                } label: {
                    HStack {
                        Text("Player Engines")
                        Spacer()
                        Text(enginePriority.map(\.displayName).joined(separator: " › "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                preferredAudioLanguageRow

                NavigationLink("VLCKit Options") { VLCEngineSettingsScreen() }
                NavigationLink("KSPlayer Options") { KSEngineSettingsScreen() }
                NavigationLink("Lume Engine Options") { LumeEngineSettingsScreen() }
            } header: {
                Text("Player")
            } footer: {
                Text("Lume plays each stream with your preferred engine and falls back to the next if it can't be played.")
            }
        }

        /// Hand-off to a third-party player. Its own group — this bypasses the
        /// engines above rather than configuring them — but headerless, so it
        /// still reads as part of the Player block.
        var externalPlayerSection: some View {
            Section {
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
            } footer: {
                // swiftlint:disable:next line_length
                Text("Streams open in the selected external app instead of Lume's player, when it is installed. Some apps — Infuse among them — play movies and series but no live channels, so you can limit the hand-off to one or the other.")
            }
        }
    }

#endif

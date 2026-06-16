//
//  SettingsView+TVPlayer.swift
//  Lume
//
//  The tvOS Player settings pane: the premium-gated playback toggles, the engine
//  priority list with reordering, the external-player cycle, and per-engine option
//  drill-ins. Split out of SettingsView to keep that file within the project's
//  line-count cap.
//

import SwiftUI

#if os(tvOS)

    extension SettingsView {
        /// The primary (most-preferred) engine — its description is shown under
        /// the priority list.
        private var primaryEngine: PlayerEngineKind {
            enginePriority.first ?? .defaultValue
        }

        /// Move the engine at `index` one slot up or down the priority list,
        /// persisting the new order and keeping the legacy single-engine key in
        /// sync with the primary so other readers (and a downgrade) still resolve it.
        private func moveEngine(at index: Int, by offset: Int) {
            var list = enginePriority
            let target = index + offset
            guard list.indices.contains(index), list.indices.contains(target) else { return }
            list.swapAt(index, target)
            let normalized = PlayerEnginePriority.normalized(list)
            enginePriorityRaw = PlayerEnginePriority.encode(normalized)
            engineRaw = normalized.first?.rawValue ?? PlayerEngineKind.defaultValue.rawValue
        }

        var tvPlayerDetail: some View {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Playback")
                    TVOptionToggleRow(title: "Autoplay Next Episode", isOn: $autoPlayNext)
                        .disabled(!premium.isPremium)
                    TVOptionToggleRow(title: "Show Next Episode Button", isOn: $showNextEpisodeButton)
                        .disabled(!premium.isPremium)
                    TVOptionToggleRow(title: "Show Skip Intro Button", isOn: $showSkipIntroButton)
                        .disabled(!premium.isPremium)
                    if !premium.isPremium {
                        Button {
                            presentPaywall(.playbackControls)
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 22, weight: .medium))
                                Text("Unlock with Premium")
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(TVSettingsRowButtonStyle())
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Engine Priority")

                    VStack(spacing: 2) {
                        ForEach(Array(enginePriority.enumerated()), id: \.element) { index, kind in
                            tvEnginePriorityRow(kind: kind, index: index)
                        }
                    }

                    Text(primaryEngine.subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("External Player")

                    TVOptionCycleRow(
                        title: "External Player",
                        valueLabel: ExternalPlayer(rawValue: externalPlayerRaw)?.displayName
                            ?? String(localized: "Off")
                    ) {
                        externalPlayerRaw = nextExternalPlayerRaw(after: externalPlayerRaw)
                    }

                    Text("Streams open in the selected app instead of Lume's player. Downloads always play in Lume, and the built-in player is used when the app is not installed.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }

                // Each engine's options live behind a dedicated row, so they're
                // all reachable regardless of the priority order. AVPlayer has no
                // configurable options, so it isn't listed.
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Engine Options")
                    VStack(spacing: 2) {
                        tvEngineOptionsRow(.vlcKit)
                        tvEngineOptionsRow(.ksPlayer)
                    }
                }
            }
        }

        /// A drill-in row that replaces the player detail with the given engine's
        /// options in place. Returning focus to the sidebar (Menu) restores it.
        private func tvEngineOptionsRow(_ engine: PlayerEngineKind) -> some View {
            Button {
                selectedEngineOptions = engine
            } label: {
                HStack(spacing: 16) {
                    Text("\(engine.displayName) Options")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }

        /// One row of the tvOS engine-priority list: the engine name, a "Primary"
        /// tag on the top entry, and up / down controls that reorder the list.
        private func tvEnginePriorityRow(kind: PlayerEngineKind, index: Int) -> some View {
            HStack(spacing: 16) {
                Text(kind.displayName)
                    .font(.system(size: TVSettingsMetrics.rowFontSize))

                if index == 0 {
                    Text("Primary")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button {
                    moveEngine(at: index, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .disabled(index == 0)
                .accessibilityLabel("Move \(kind.displayName) up")

                Button {
                    moveEngine(at: index, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .disabled(index == enginePriority.count - 1)
                .accessibilityLabel("Move \(kind.displayName) down")
            }
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            .padding(.vertical, TVSettingsMetrics.rowVPadding)
            .background(
                RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
    }

#endif

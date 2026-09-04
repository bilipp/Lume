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
            guard list.move(at: index, by: offset) else { return }
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
                                Image(systemName: "crown")
                                    .font(.system(size: 22, weight: .medium))
                                Text("Unlock with Premium")
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(TVSettingsRowButtonStyle())
                    }
                }

                // Second in the pane, right under Playback: this is a
                // viewer-facing playback preference (and the one that otherwise
                // costs a menu trip on every zap), where everything below —
                // engine order, hand-off, per-engine options — is technical
                // setup touched once.
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Languages")

                    VStack(spacing: 2) {
                        tvPreferredLanguageRow()
                    }
                }

                // Viewer-facing too, so it belongs up here with Languages
                // rather than among the engine sections — and it is
                // engine-independent: all four hosts route their up/down
                // presses through LiveChannelNavigator.
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Live TV")

                    TVOptionCycleRow(
                        title: "Up & Down",
                        valueLabel: LiveSurfMode.resolve(liveSurfModeRaw).displayName
                    ) {
                        liveSurfModeRaw = nextLiveSurfModeRaw(after: liveSurfModeRaw)
                    }

                    Text("Up and down move to the next and previous channel, like a TV remote. List Order moves the way the channel list reads on screen instead — up goes to the row above.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
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

                    // Only meaningful once a player is selected — some players
                    // (Infuse, for one) handle VOD but not live streams.
                    if ExternalPlayer(rawValue: externalPlayerRaw) != nil {
                        TVOptionCycleRow(
                            title: "Use For",
                            valueLabel: ExternalPlayerScope(rawValue: externalPlayerScopeRaw)?.displayName
                                ?? ExternalPlayerScope.default.displayName
                        ) {
                            externalPlayerScopeRaw = nextExternalPlayerScopeRaw(after: externalPlayerScopeRaw)
                        }
                    }

                    // swiftlint:disable:next line_length
                    Text("Streams open in the selected app instead of Lume's player. Downloads always play in Lume, and the built-in player is used when the app is not installed or the stream is outside the selected content.")
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
                        tvEngineOptionsRow(.lumeEngine)
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
            TVSettingsReorderRow(
                name: kind.displayName,
                index: index,
                count: enginePriority.count,
                onMove: { moveEngine(at: index, by: $0) },
                leading: {
                    Text(kind.displayName)
                        .font(.system(size: TVSettingsMetrics.rowFontSize))

                    if index == 0 {
                        Text("Primary")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            )
        }

        // MARK: - Preferred languages

        /// The stored list, most-preferred first. Empty is the shipped default
        /// and means "no preference".
        private var preferredLanguageCodes: [String] {
            PreferredLanguageList.decode(preferredAudioLanguagesRaw)
        }

        /// Deferred: the reorder and remove buttons run inside the focus
        /// engine's animated context, and rewriting the list rebuilds the
        /// `ForEach` under it. Mutating on the next turn lets the engine finish
        /// the move it is already animating and keeps focus on the row.
        private func setPreferredLanguageCodes(_ codes: [String]) {
            let encoded = PreferredLanguageList.encode(codes)
            Task { preferredAudioLanguagesRaw = encoded }
        }

        private func movePreferredLanguage(at index: Int, by offset: Int) {
            var list = preferredLanguageCodes
            guard list.move(at: index, by: offset) else { return }
            setPreferredLanguageCodes(list)
        }

        private func removePreferredLanguage(at index: Int) {
            var list = preferredLanguageCodes
            guard list.indices.contains(index) else { return }
            list.remove(at: index)
            setPreferredLanguageCodes(list)
        }

        /// A drill-in row that replaces the player detail with the language
        /// list in place, mirroring `tvEngineOptionsRow`.
        private func tvPreferredLanguageRow() -> some View {
            Button {
                preferredLanguagePane = .list
            } label: {
                HStack(spacing: 16) {
                    Text("Audio Languages")
                    Spacer(minLength: 16)
                    tvPreferredLanguageValue
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }

        /// The row's trailing summary. `.opacity` rather than `.secondary`: the
        /// focused row's label turns black, which a secondary style washes out.
        @ViewBuilder
        private var tvPreferredLanguageValue: some View {
            let codes = preferredLanguageCodes
            Group {
                if codes.isEmpty {
                    Text("Automatic")
                } else {
                    Text(verbatim: codes.map { TrackLanguageMatcher.displayName(for: $0) }.joined(separator: ", "))
                }
            }
            .font(.system(size: TVSettingsMetrics.secondaryFontSize))
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(0.6)
        }

        /// The drilled-in pane for the language list: the ordered list itself,
        /// or the add picker one level deeper.
        @ViewBuilder
        func tvPreferredLanguageDetail(_ pane: PreferredLanguagePane) -> some View {
            switch pane {
            case .list: tvPreferredLanguageOrderDetail()
            case .add: tvAddPreferredLanguageDetail()
            }
        }

        private func tvPreferredLanguageOrderDetail() -> some View {
            let codes = preferredLanguageCodes
            return VStack(alignment: .leading, spacing: 28) {
                Text("Audio Languages")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Preferred Order")

                    if codes.isEmpty {
                        Text("No Preferred Languages")
                            .tvSettingsSecondaryText()
                    } else {
                        VStack(spacing: 2) {
                            ForEach(Array(codes.enumerated()), id: \.element) { index, code in
                                tvPreferredLanguageOrderRow(code: code, index: index, count: codes.count)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        preferredLanguagePane = .add
                    } label: {
                        HStack(spacing: 16) {
                            Text("Add Language")
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())

                    Text(tvPreferredLanguageFooter)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var tvPreferredLanguageFooter: LocalizedStringKey {
            // swiftlint:disable:next line_length
            "Lume selects the first of these languages the stream offers as an audio track, most preferred at the top. When the audio that plays is in none of them and the stream carries a forced subtitle track, that track is turned on. Applied the next time playback starts."
        }

        /// One row of the ordered list: the language's name, reorder controls
        /// and a remove button.
        private func tvPreferredLanguageOrderRow(
            code: String,
            index: Int,
            count: Int
        ) -> some View {
            let name = TrackLanguageMatcher.displayName(for: code)
            return TVSettingsReorderRow(
                name: name,
                index: index,
                count: count,
                onMove: { movePreferredLanguage(at: index, by: $0) },
                onRemove: { removePreferredLanguage(at: index) },
                leading: {
                    Text(verbatim: name)
                        .font(.system(size: TVSettingsMetrics.rowFontSize))
                }
            )
        }

        /// The add picker: the device's own languages first, then the curated
        /// shortlist. Deliberately not the full ISO list — several hundred
        /// focusable rows is a scroll and VoiceOver hazard on tvOS, and this
        /// pane has no search field.
        private func tvAddPreferredLanguageDetail() -> some View {
            let addable = PreferredLanguageCatalog.addable(excluding: preferredLanguageCodes)

            return VStack(alignment: .leading, spacing: 28) {
                Text("Add Language")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                if !addable.suggested.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        TVSettingsSectionLabel("Suggested")
                        VStack(spacing: 2) {
                            ForEach(addable.suggested) { tvAddPreferredLanguageRow($0) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Common Languages")
                    if addable.common.isEmpty {
                        Text("No Languages Found")
                            .tvSettingsSecondaryText()
                    } else {
                        VStack(spacing: 2) {
                            ForEach(addable.common) { tvAddPreferredLanguageRow($0) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func tvAddPreferredLanguageRow(_ language: PreferredLanguage) -> some View {
            Button {
                setPreferredLanguageCodes(preferredLanguageCodes + [language.code])
                preferredLanguagePane = .list
            } label: {
                HStack(spacing: 16) {
                    Text(verbatim: language.name)
                    Spacer(minLength: 16)
                    Text(verbatim: language.code.uppercased())
                        .font(.system(size: TVSettingsMetrics.secondaryFontSize).monospaced())
                        .opacity(0.6)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }
    }

#endif

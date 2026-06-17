//
//  SettingsView+TVHome.swift
//  Lume
//
//  The tvOS Home settings pane: each Home row can be switched on or off and
//  reordered with up / down controls. Mirrors the engine priority pane
//  (SettingsView+TVPlayer) and the iOS HomeLayoutSettingsView.
//

import SwiftUI

#if os(tvOS)

    extension SettingsView {
        /// The user's resolved Home row order (falls back to the declaration
        /// order until they reorder). See `HomeLayoutSettings`.
        private var homeSections: [HomeSection] {
            HomeLayoutSettings.resolve(orderRaw: homeSectionOrderRaw)
        }

        /// Whether `section` is switched on. "For You" maps to the recommendations
        /// flag; every other section is tracked by the disabled set.
        private func isHomeSectionEnabled(_ section: HomeSection) -> Bool {
            section == .forYou
                ? recommendationsEnabled
                : HomeLayoutSettings.isEnabled(section, disabledRaw: homeDisabledSectionsRaw)
        }

        private func toggleHomeSection(_ section: HomeSection) {
            if section == .forYou {
                // "For You" is a Lume Pro feature — gate turning it on behind the
                // paywall (disabling it is always allowed).
                if !recommendationsEnabled, !premium.isPremium {
                    presentPaywall(.recommendations)
                    return
                }
                recommendationsEnabled.toggle()
                return
            }
            var disabled = HomeLayoutSettings.decodeDisabled(homeDisabledSectionsRaw)
            if disabled.contains(section) { disabled.remove(section) } else { disabled.insert(section) }
            homeDisabledSectionsRaw = HomeLayoutSettings.encodeDisabled(disabled)
        }

        /// Move the section at `index` one slot up or down, persisting the new
        /// order. Mirrors `moveEngine` in the player pane.
        private func moveSection(at index: Int, by offset: Int) {
            var list = homeSections
            let target = index + offset
            guard list.indices.contains(index), list.indices.contains(target) else { return }
            list.swapAt(index, target)
            homeSectionOrderRaw = HomeLayoutSettings.encode(HomeLayoutSettings.normalized(list))
        }

        var tvHomeLayoutDetail: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Sections")

                VStack(spacing: 2) {
                    ForEach(Array(homeSections.enumerated()), id: \.element) { index, section in
                        tvHomeSectionRow(section: section, index: index)
                    }
                }

                Text("Turn sections on or off and reorder them. Each appears on Home only when it has something to show. \"For You\" is built on-device from your library and what you watch.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 6)
            }
        }

        /// One row of the tvOS Home section list: an on/off control, the section
        /// name, and up / down controls that reorder the list. Mirrors
        /// `tvEnginePriorityRow`.
        private func tvHomeSectionRow(section: HomeSection, index: Int) -> some View {
            let enabled = isHomeSectionEnabled(section)
            return HStack(spacing: 16) {
                Button {
                    toggleHomeSection(section)
                } label: {
                    Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .accessibilityLabel(section.displayName)
                .accessibilityValue(enabled ? Text("On") : Text("Off"))

                Label(section.title, systemImage: section.systemImage)
                    .font(.system(size: TVSettingsMetrics.rowFontSize))
                    .foregroundStyle(enabled ? .primary : .secondary)

                // "For You" is a Lume Pro feature; badge it for free users
                // (Sideload/owned builds are always premium, so this never shows).
                if section == .forYou, !premium.isPremium {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tint)
                }

                Spacer(minLength: 0)

                Button {
                    moveSection(at: index, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .disabled(index == 0)
                .accessibilityLabel("Move \(section.displayName) up")

                Button {
                    moveSection(at: index, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .disabled(index == homeSections.count - 1)
                .accessibilityLabel("Move \(section.displayName) down")
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

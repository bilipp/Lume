//
//  TVTopShelfSettingsSection.swift
//  Lume
//
//  The Top Shelf block of the tvOS Home settings pane: switch Lume's Top Shelf
//  off, pick rows or the backdrop carousel, choose how many items a section
//  holds, and turn sections on or off and reorder them like the Home rows.
//  Stored per device (see `TopShelfSettings`); every change is written into
//  the snapshot straight away so the Top Shelf follows without a re-export.
//

import SwiftUI

#if os(tvOS)

    struct TVTopShelfSettingsSection: View {
        @AppStorage(TopShelfSettings.enabledKey) private var isEnabled = TopShelfConfiguration.default.isEnabled
        @AppStorage(TopShelfSettings.styleKey) private var styleRaw = TopShelfConfiguration.default.style.rawValue
        @AppStorage(TopShelfSettings.itemsPerSectionKey) private var itemsPerSection = TopShelfConfiguration.default.itemsPerSection
        @AppStorage(TopShelfSettings.sectionOrderKey) private var sectionOrderRaw = ""
        @AppStorage(TopShelfSettings.disabledSectionsKey) private var disabledSectionsRaw = ""

        private var sections: [TopShelfSettings.Section] {
            TopShelfSettings.resolve(orderRaw: sectionOrderRaw)
        }

        private var disabledSections: Set<TopShelfSettings.Section> {
            Set(TopShelfSettings.decode(disabledSectionsRaw))
        }

        private var style: TopShelfConfiguration.Style {
            TopShelfConfiguration.Style(rawValue: styleRaw) ?? TopShelfConfiguration.default.style
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Top Shelf")

                TVOptionToggleRow(title: "Show in Top Shelf", isOn: $isEnabled)

                if isEnabled {
                    TVOptionCycleRow(title: "Layout", valueLabel: style.label) {
                        styleRaw = style == .sectioned
                            ? TopShelfConfiguration.Style.carousel.rawValue
                            : TopShelfConfiguration.Style.sectioned.rawValue
                    }

                    TVOptionCycleRow(title: "Items per Section", valueLabel: "\(itemsPerSection)") {
                        itemsPerSection = Self.nextItemCount(after: itemsPerSection)
                    }

                    VStack(spacing: 2) {
                        ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                            sectionRow(section, index: index)
                        }
                    }
                    .padding(.top, 8)
                }

                Group {
                    Text("What Lume shows above its icon on the Apple TV Home Screen. A section appears only when it has something to show. When switched off, the Top Shelf shows the Lume artwork.")
                    if isEnabled, style == .carousel {
                        Text("The carousel shows movies and series. Channels have no wide artwork, so they appear only in Rows.")
                    }
                }
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 6)
            }
            .onChange(of: TopShelfSettings.configuration()) {
                TopShelfSettings.apply()
            }
        }

        /// One section row: an on/off control, the section name, and up / down
        /// controls. Mirrors the Home section rows above it.
        private func sectionRow(_ section: TopShelfSettings.Section, index: Int) -> some View {
            let enabled = !disabledSections.contains(section)
            return TVSettingsReorderRow(
                name: section.displayName,
                index: index,
                count: sections.count,
                onMove: { move(at: index, by: $0) },
                leading: {
                    Button {
                        var disabled = disabledSections
                        if enabled { disabled.insert(section) } else { disabled.remove(section) }
                        disabledSectionsRaw = TopShelfSettings.encode(disabled, sorted: true)
                    } label: {
                        Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(TVContentIconButtonStyle())
                    .accessibilityLabel(section.displayName)
                    .accessibilityValue(enabled ? Text("On") : Text("Off"))

                    Label(section.title, systemImage: section.systemImage)
                        .font(.system(size: TVSettingsMetrics.rowFontSize))
                        .foregroundStyle(enabled ? .primary : .secondary)
                }
            )
        }

        private func move(at index: Int, by offset: Int) {
            var list = sections
            guard list.move(at: index, by: offset) else { return }
            sectionOrderRaw = TopShelfSettings.encode(list)
        }

        /// The next item-count choice, wrapping around after the largest.
        static func nextItemCount(after current: Int) -> Int {
            let choices = TopShelfConfiguration.itemCountChoices
            guard let index = choices.firstIndex(of: current) else { return choices[0] }
            return choices[(index + 1) % choices.count]
        }
    }

    private extension TopShelfConfiguration.Style {
        var label: String {
            switch self {
            case .sectioned: String(localized: "Rows", comment: "Top Shelf layout: rows of posters under section titles")
            case .carousel: String(localized: "Carousel", comment: "Top Shelf layout: full-width backdrop carousel")
            }
        }
    }

    private extension TopShelfConfiguration.Section {
        var title: LocalizedStringKey {
            switch self {
            case .continueWatching: "Continue Watching"
            case .favorites: "Favorites"
            }
        }

        var displayName: String {
            switch self {
            case .continueWatching: String(localized: "Continue Watching")
            case .favorites: String(localized: "Favorites")
            }
        }

        var systemImage: String {
            switch self {
            case .continueWatching: "clock.arrow.circlepath"
            case .favorites: "star"
            }
        }
    }

#endif

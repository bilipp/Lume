//
//  TopShelfSettings.swift
//  Lume
//
//  The user's Top Shelf choices (Settings › Home on tvOS). Stored per device in
//  plain UserDefaults — each Apple TV has its own Top Shelf, so the choice is
//  deliberately not synced. Small scalars, so @AppStorage-friendly keys in the
//  shape `HomeLayoutSettings` uses: the section order and the switched-off
//  sections are comma-separated lists of `TopShelfConfiguration.Section` raw
//  values.
//

import Foundation
import OSLog
#if os(tvOS)
    import TVServices
#endif

nonisolated enum TopShelfSettings {
    typealias Section = TopShelfConfiguration.Section

    static let enabledKey = "topShelf.enabled.v1"
    static let styleKey = "topShelf.style.v1"
    /// Stored section order. Empty until the user reorders, in which case the
    /// declaration order of `Section` applies.
    static let sectionOrderKey = "topShelf.sectionOrder.v1"
    /// Sections the user switched off. Absence means on.
    static let disabledSectionsKey = "topShelf.disabledSections.v1"
    static let itemsPerSectionKey = "topShelf.itemsPerSection.v1"

    /// The stored choices as the configuration the Top Shelf reads.
    static func configuration(defaults: UserDefaults = .standard) -> TopShelfConfiguration {
        let fallback = TopShelfConfiguration.default
        let disabled = Set(decode(defaults.string(forKey: disabledSectionsKey) ?? ""))
        let count = defaults.integer(forKey: itemsPerSectionKey)
        return TopShelfConfiguration(
            isEnabled: defaults.object(forKey: enabledKey) as? Bool ?? fallback.isEnabled,
            style: defaults.string(forKey: styleKey).flatMap(TopShelfConfiguration.Style.init) ?? fallback.style,
            sections: resolve(orderRaw: defaults.string(forKey: sectionOrderKey) ?? "").filter { !disabled.contains($0) },
            itemsPerSection: TopShelfConfiguration.itemCountChoices.contains(count) ? count : fallback.itemsPerSection
        )
    }

    /// Rewrites the configuration into the existing snapshot and asks tvOS to
    /// reload the Top Shelf, so a settings change shows without a re-export.
    static func apply(defaults: UserDefaults = .standard) {
        var snapshot = WidgetDataStore.load() ?? .empty
        snapshot.topShelf = configuration(defaults: defaults)
        do {
            try WidgetDataStore.save(snapshot)
        } catch {
            Logger.database.error("Top Shelf settings not saved: \(error.localizedDescription, privacy: .public)")
            return
        }
        #if os(tvOS)
            TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    // MARK: - Section list encoding

    /// Every section exactly once: the stored order first, then any section
    /// it is missing, in declaration order.
    static func resolve(orderRaw: String) -> [Section] {
        var seen = Set<Section>()
        return (decode(orderRaw) + Section.allCases).filter { seen.insert($0).inserted }
    }

    static func decode(_ raw: String) -> [Section] {
        raw.split(separator: ",").compactMap { Section(rawValue: String($0)) }
    }

    /// Sets encode sorted, so the stored value doesn't churn as it's mutated.
    static func encode(_ sections: some Sequence<Section>, sorted: Bool = false) -> String {
        let raw = sections.map(\.rawValue)
        return (sorted ? raw.sorted() : raw).joined(separator: ",")
    }
}

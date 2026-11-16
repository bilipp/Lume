//
//  WhatsNewCatalog.swift
//  Lume
//
//  Every release's user-facing changes, newest first. A feature adds its entry
//  here in the same change, under the version it will ship in; the strings live
//  in the `WhatsNew` String Catalog, in every shipping language.
//
//  The copy follows the App Store "What’s New" rules: only what is in the
//  build, limited to the platforms that have it (`platforms`), no provider
//  names, no pricing, no other stores.
//

import Foundation

nonisolated enum WhatsNewCatalog {
    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(
            version: AppVersion(3, 3),
            highlights: [
                WhatsNewItem(
                    id: "3.3.stalker-guide",
                    symbol: "calendar.day.timeline.left",
                    title: text("whatsNew.3_3.stalkerGuide.title", "TV Guide for Stalker Portals"),
                    summary: text(
                        "whatsNew.3_3.stalkerGuide.summary",
                        "Stalker and Ministra playlists now fill the TV guide straight from the portal."
                    )
                ),
                WhatsNewItem(
                    id: "3.3.guide-default",
                    symbol: "tv",
                    title: text("whatsNew.3_3.guideDefault.title", "Live TV Opens in the Guide"),
                    summary: text(
                        "whatsNew.3_3.guideDefault.summary",
                        "See what’s on right away. If you chose the list layout before, Lume keeps it."
                    )
                ),
                WhatsNewItem(
                    id: "3.3.mac-current-window",
                    symbol: "macwindow",
                    title: text("whatsNew.3_3.macCurrentWindow.title", "Play in the Current Window"),
                    summary: text(
                        "whatsNew.3_3.macCurrentWindow.summary",
                        "A new Player setting opens videos in the library window instead of a new one."
                    ),
                    platforms: [.macOS]
                ),
                WhatsNewItem(
                    id: "3.3.languages",
                    symbol: "globe",
                    title: text("whatsNew.3_3.languages.title", "Four New Languages"),
                    summary: text(
                        "whatsNew.3_3.languages.summary",
                        "Lume is now available in Dutch, Polish, Russian and Turkish."
                    )
                )
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(3, 2),
            highlights: [
                WhatsNewItem(
                    id: "3.2.duplicate-titles",
                    symbol: "square.stack",
                    title: text("whatsNew.3_2.duplicateTitles.title", "One Card per Title"),
                    summary: text(
                        "whatsNew.3_2.duplicateTitles.summary",
                        "Movies and series your playlists carry more than once can show as one card, with a source picker on Play. Turn on Group Duplicate Titles in Settings."
                    )
                ),
                WhatsNewItem(
                    id: "3.2.combined-lume-cloud",
                    symbol: "arrow.triangle.2.circlepath",
                    title: text("whatsNew.3_2.combinedLumeCloud.title", "Combined View on Lume Cloud"),
                    summary: text(
                        "whatsNew.3_2.combinedLumeCloud.summary",
                        "Your Combined View setup now syncs across your devices with Lume Cloud too."
                    )
                )
            ],
            notes: [
                text(
                    "whatsNew.3_2.engineOrder.note",
                    "New installs try AetherEngine first. An engine order you saved is kept."
                )
            ]
        )
    ]

    /// The releases the history lists in a build of `current`: the ones it
    /// contains, with something to say on `platform`. An entry filed under a
    /// version that hasn't shipped yet stays out until the build carries it.
    static func history(
        for current: AppVersion?,
        on platform: WhatsNewPlatform,
        releases: [WhatsNewRelease] = releases
    ) -> [WhatsNewRelease] {
        releases.filter { release in
            guard release.hasContent(on: platform) else { return false }
            guard let current else { return true }
            return release.version.feature <= current.feature
        }
    }

    /// The keys are not literals at the `LocalizedStringResource` call, so
    /// Xcode can't extract them: their catalog entries are `manual`.
    private static func text(_ key: StaticString, _ english: String) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: String.LocalizationValue(english), table: "WhatsNew")
    }
}

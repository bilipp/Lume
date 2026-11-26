//
//  WhatsNewCatalog.swift
//  Lume
//
//  Every release's user-facing changes, newest first: 3.x here, 2.x and 1.x
//  in `WhatsNewCatalog+2` and `+1`. A feature adds its entry here in the same
//  change, under the version it will ship in; the strings live in the
//  `WhatsNew` String Catalog, in every shipping language. Patch releases have
//  no entry of their own: their changes go under the feature release.
//
//  Written for viewers, not developers: what they can now do or what got
//  better, in plain words, no technical terms.
//
//  The copy follows the App Store "What’s New" rules: only what is in the
//  build, limited to the platforms that have it (`platforms`), no provider
//  names, no pricing, no other stores.
//

import Foundation

nonisolated enum WhatsNewCatalog {
    /// Every release, newest first. 2.x and 1.x live in their own files.
    static let releases: [WhatsNewRelease] = releases3 + releases2 + releases1

    private static let releases3: [WhatsNewRelease] = [
        WhatsNewRelease(
            version: AppVersion(3, 5),
            highlights: [
                WhatsNewItem(
                    id: "3.5.tab-order",
                    symbol: "arrow.up.arrow.down",
                    title: text("whatsNew.3_5.tabOrder.title", "Arrange Your Tabs"),
                    summary: text(
                        "whatsNew.3_5.tabOrder.summary",
                        "Put the tabs in the order you like and hide the ones you don’t use, Home included. Find it in Settings › Library."
                    )
                )
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(3, 4),
            highlights: [
                WhatsNewItem(
                    id: "3.4.background-sync",
                    symbol: "arrow.triangle.2.circlepath",
                    title: text("whatsNew.3_4.backgroundSync.title", "Sync in the Background"),
                    summary: text(
                        "whatsNew.3_4.backgroundSync.summary",
                        "Playlists now sync while you keep browsing. New titles show up as they arrive."
                    )
                ),
                WhatsNewItem(
                    id: "3.4.stream-details",
                    symbol: "info.circle",
                    title: text("whatsNew.3_4.streamDetails.title", "Stream Details at a Glance"),
                    summary: text(
                        "whatsNew.3_4.streamDetails.summary",
                        "The player now shows the picture size, HDR format, audio and bitrate of what you’re watching."
                    )
                )
            ]
        ),
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
                    id: "3.2.tracks-stay",
                    symbol: "captions.bubble",
                    title: text("whatsNew.3_2.tracksStay.title", "Your Tracks Stay Picked"),
                    summary: text(
                        "whatsNew.3_2.tracksStay.summary",
                        "Subtitles and audio you choose by hand stay selected for the next episode."
                    )
                )
            ],
            notes: [
                text("whatsNew.3_2.jellyfinFaster.note", "Jellyfin libraries load faster.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(3, 1),
            highlights: [
                WhatsNewItem(
                    id: "3.1.combined-view",
                    symbol: "square.stack.3d.down.right",
                    title: text("whatsNew.3_1.combinedView.title", "Combined View (Beta)"),
                    summary: text(
                        "whatsNew.3_1.combinedView.summary",
                        "Browse several playlists together in Live TV, Movies and Series."
                    ),
                    isPro: true
                ),
                WhatsNewItem(
                    id: "3.1.server-downloads",
                    symbol: "arrow.down.circle",
                    title: text("whatsNew.3_1.serverDownloads.title", "Download from Your Media Server"),
                    summary: text(
                        "whatsNew.3_1.serverDownloads.summary",
                        "Save movies and episodes from Plex, Jellyfin, Emby, Silo and WebDAV to watch offline."
                    ),
                    platforms: [.iOS, .macOS],
                    isPro: true
                ),
                WhatsNewItem(
                    id: "3.1.hue",
                    symbol: "lightbulb.2",
                    title: text("whatsNew.3_1.hue.title", "Philips Hue Light Sync"),
                    summary: text(
                        "whatsNew.3_1.hue.summary",
                        "Your Hue lights follow the colours of the picture."
                    ),
                    platforms: [.tvOS],
                    isPro: true
                )
            ],
            notes: [
                text("whatsNew.3_1.newPlayer.note", "A new player option is available in Settings › Player."),
                text("whatsNew.3_1.favoritesKept.note", "Favorites and hidden channels no longer disappear after a sync reset.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(3, 0),
            highlights: [
                WhatsNewItem(
                    id: "3.0.lume-cloud",
                    symbol: "lock.icloud",
                    title: text("whatsNew.3_0.lumeCloud.title", "Lume Cloud"),
                    summary: text(
                        "whatsNew.3_0.lumeCloud.summary",
                        "A private way to sync next to iCloud, which also works with Lume on Android."
                    )
                ),
                WhatsNewItem(
                    id: "3.0.choose-sync",
                    symbol: "arrow.triangle.2.circlepath.icloud",
                    title: text("whatsNew.3_0.chooseSync.title", "Choose How to Sync"),
                    summary: text(
                        "whatsNew.3_0.chooseSync.summary",
                        "Pick iCloud, Lume Cloud or no sync when you set up Lume."
                    )
                ),
                WhatsNewItem(
                    id: "3.0.watched-badges",
                    symbol: "checkmark.circle",
                    title: text("whatsNew.3_0.watchedBadges.title", "Watched Badges"),
                    summary: text(
                        "whatsNew.3_0.watchedBadges.summary",
                        "See at a glance what you’ve already watched."
                    )
                )
            ],
            notes: [
                text("whatsNew.3_0.syncNow.note", "Sync Now in Settings › Sync."),
                text("whatsNew.3_0.skipIntro.note", "Skip Intro stays reachable when the player controls are showing.")
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
    static func text(_ key: StaticString, _ english: String) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: String.LocalizationValue(english), table: "WhatsNew")
    }
}

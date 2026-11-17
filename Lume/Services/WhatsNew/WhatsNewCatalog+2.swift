//
//  WhatsNewCatalog+2.swift
//  Lume
//
//  The 2.x releases of the What’s New history, newest first.
//

import Foundation

extension WhatsNewCatalog {
    static let releases2: [WhatsNewRelease] = [
        WhatsNewRelease(
            version: AppVersion(2, 8),
            highlights: [
                WhatsNewItem(
                    id: "2.8.chromecast",
                    symbol: "tv.badge.wifi",
                    title: text("whatsNew.2_8.chromecast.title", "Chromecast"),
                    summary: text(
                        "whatsNew.2_8.chromecast.summary",
                        "Cast what you’re watching to a Chromecast."
                    ),
                    platforms: [.iOS],
                    isPro: true
                ),
                WhatsNewItem(
                    id: "2.8.keyboard",
                    symbol: "keyboard",
                    title: text("whatsNew.2_8.keyboard.title", "Keyboard Shortcuts"),
                    summary: text(
                        "whatsNew.2_8.keyboard.summary",
                        "Control the player with the keyboard."
                    ),
                    platforms: [.iOS, .macOS]
                ),
                WhatsNewItem(
                    id: "2.8.jellyfin-seasons",
                    symbol: "square.stack.3d.up",
                    title: text("whatsNew.2_8.jellyfinSeasons.title", "Jellyfin Shows by Season"),
                    summary: text(
                        "whatsNew.2_8.jellyfinSeasons.summary",
                        "Shows are sorted by season, and you can pick between versions of an episode."
                    )
                )
            ],
            notes: [
                text("whatsNew.2_8.mdblist.note", "Sync watched titles and your watchlist with MDBList."),
                text("whatsNew.2_8.resumeSaved.note", "Your place is saved if the app closes during playback.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(2, 7),
            highlights: [
                WhatsNewItem(
                    id: "2.7.widgets",
                    symbol: "square.grid.2x2",
                    title: text("whatsNew.2_7.widgets.title", "Home Screen Widgets"),
                    summary: text(
                        "whatsNew.2_7.widgets.summary",
                        "Continue Watching, Favorites and On Now, right on your Home Screen."
                    ),
                    platforms: [.iOS]
                ),
                WhatsNewItem(
                    id: "2.7.top-shelf",
                    symbol: "rectangle.topthird.inset.filled",
                    title: text("whatsNew.2_7.topShelf.title", "Top Shelf"),
                    summary: text(
                        "whatsNew.2_7.topShelf.summary",
                        "Continue Watching and Favorites on the Apple TV Home Screen."
                    ),
                    platforms: [.tvOS]
                ),
                WhatsNewItem(
                    id: "2.7.tv-settings",
                    symbol: "gearshape",
                    title: text("whatsNew.2_7.tvSettings.title", "New Settings Look"),
                    summary: text(
                        "whatsNew.2_7.tvSettings.summary",
                        "Settings get the Live TV look and smoother navigation."
                    ),
                    platforms: [.tvOS]
                ),
                WhatsNewItem(
                    id: "2.7.arabic",
                    symbol: "globe",
                    title: text("whatsNew.2_7.arabic.title", "Arabic"),
                    summary: text(
                        "whatsNew.2_7.arabic.summary",
                        "Lume now speaks Arabic, with a right-to-left layout."
                    )
                )
            ],
            notes: [
                text("whatsNew.2_7.silo.note", "Silo can be added as a media server."),
                text("whatsNew.2_7.releaseYear.note", "Movie and series pages show the release year.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(2, 6),
            highlights: [
                WhatsNewItem(
                    id: "2.6.watch-from-start",
                    symbol: "backward.end",
                    title: text("whatsNew.2_6.watchFromStart.title", "Watch from the Start"),
                    summary: text(
                        "whatsNew.2_6.watchFromStart.summary",
                        "Start a programme that’s already on from the beginning."
                    )
                ),
                WhatsNewItem(
                    id: "2.6.subtitle-style",
                    symbol: "textformat",
                    title: text("whatsNew.2_6.subtitleStyle.title", "Subtitle Styles"),
                    summary: text(
                        "whatsNew.2_6.subtitleStyle.summary",
                        "Choose the size, font, colour and background of subtitles, with a live preview."
                    )
                ),
                WhatsNewItem(
                    id: "2.6.landscape",
                    symbol: "iphone.landscape",
                    title: text("whatsNew.2_6.landscape.title", "Landscape Player"),
                    summary: text(
                        "whatsNew.2_6.landscape.summary",
                        "Let the player turn to landscape on iPhone."
                    ),
                    platforms: [.iOS]
                )
            ],
            notes: [
                text("whatsNew.2_6.moreCatchUp.note", "Catch-up works with more playlists."),
                text("whatsNew.2_6.offlineAgain.note", "Downloaded videos play offline again after an update.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(2, 5),
            highlights: [
                WhatsNewItem(
                    id: "2.5.mac-volume",
                    symbol: "speaker.wave.3",
                    title: text("whatsNew.2_5.macVolume.title", "Volume in the Player"),
                    summary: text(
                        "whatsNew.2_5.macVolume.summary",
                        "Change the volume or mute right in the player, also with the keyboard."
                    ),
                    platforms: [.macOS]
                ),
                WhatsNewItem(
                    id: "2.5.downloads-row",
                    symbol: "arrow.down.circle",
                    title: text("whatsNew.2_5.downloadsRow.title", "Downloads on Home"),
                    summary: text(
                        "whatsNew.2_5.downloadsRow.summary",
                        "Add a Downloads row to Home."
                    ),
                    platforms: [.iOS, .macOS, .visionOS]
                ),
                WhatsNewItem(
                    id: "2.5.live-rail",
                    symbol: "eye.slash",
                    title: text("whatsNew.2_5.liveRail.title", "Tidy Up Live TV"),
                    summary: text(
                        "whatsNew.2_5.liveRail.summary",
                        "Hide Favorites or Recently Watched from the Live TV list."
                    )
                )
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(2, 4),
            highlights: [
                WhatsNewItem(
                    id: "2.4.recording",
                    symbol: "record.circle",
                    title: text("whatsNew.2_4.recording.title", "Record Live TV"),
                    summary: text(
                        "whatsNew.2_4.recording.summary",
                        "Record to your own recording server, and schedule programmes from the guide."
                    ),
                    isPro: true
                ),
                WhatsNewItem(
                    id: "2.4.programme-menu",
                    symbol: "hand.tap",
                    title: text("whatsNew.2_4.programmeMenu.title", "Programme Shortcuts"),
                    summary: text(
                        "whatsNew.2_4.programmeMenu.summary",
                        "Long-press a programme in the guide to watch, record or see details."
                    )
                ),
                WhatsNewItem(
                    id: "2.4.guide-cards",
                    symbol: "rectangle.grid.1x2",
                    title: text("whatsNew.2_4.guideCards.title", "A New TV Guide"),
                    summary: text(
                        "whatsNew.2_4.guideCards.summary",
                        "The guide uses the same programme cards as on Apple TV."
                    ),
                    platforms: [.iOS, .macOS]
                )
            ],
            notes: [
                text("whatsNew.2_4.pipKeepsPlaying.note", "Videos keep playing when Picture in Picture starts.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(2, 3),
            highlights: [
                WhatsNewItem(
                    id: "2.3.live-preview",
                    symbol: "pip",
                    title: text("whatsNew.2_3.livePreview.title", "Live Preview in the Guide"),
                    summary: text(
                        "whatsNew.2_3.livePreview.summary",
                        "Keep watching the current channel while you browse the guide."
                    ),
                    platforms: [.tvOS],
                    isPro: true
                ),
                WhatsNewItem(
                    id: "2.3.live-t-v-screen",
                    symbol: "tv",
                    title: text("whatsNew.2_3.liveTVScreen.title", "A New Live TV Screen"),
                    summary: text(
                        "whatsNew.2_3.liveTVScreen.summary",
                        "Live TV is rebuilt around the live preview."
                    ),
                    platforms: [.tvOS]
                ),
                WhatsNewItem(
                    id: "2.3.no-black-screen",
                    symbol: "film",
                    title: text("whatsNew.2_3.noBlackScreen.title", "Smoother Channel Changes"),
                    summary: text(
                        "whatsNew.2_3.noBlackScreen.summary",
                        "Changing channels keeps the last picture until the next one starts."
                    )
                )
            ],
            notes: [
                text("whatsNew.2_3.moreAccounts.note", "Live channels play on more accounts."),
                text("whatsNew.2_3.matchContent.note", "Changing channels no longer makes your TV go dark when Match Content is on.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(2, 2),
            highlights: [
                WhatsNewItem(
                    id: "2.2.settings",
                    symbol: "gearshape",
                    title: text("whatsNew.2_2.settings.title", "Redesigned Settings"),
                    summary: text(
                        "whatsNew.2_2.settings.summary",
                        "Settings are grouped into clear sections, one page per topic."
                    )
                ),
                WhatsNewItem(
                    id: "2.2.hide-tabs",
                    symbol: "rectangle.on.rectangle.slash",
                    title: text("whatsNew.2_2.hideTabs.title", "Hide Tabs per Playlist"),
                    summary: text(
                        "whatsNew.2_2.hideTabs.summary",
                        "Hide the Movies, Series or Live TV tab when a playlist doesn’t need it."
                    )
                ),
                WhatsNewItem(
                    id: "2.2.hide-scores",
                    symbol: "eye.slash",
                    title: text("whatsNew.2_2.hideScores.title", "No Spoilers"),
                    summary: text(
                        "whatsNew.2_2.hideScores.summary",
                        "Hide the scores on game cards and in game details."
                    )
                ),
                WhatsNewItem(
                    id: "2.2.faster-sync",
                    symbol: "bolt",
                    title: text("whatsNew.2_2.fasterSync.title", "Faster Syncing"),
                    summary: text(
                        "whatsNew.2_2.fasterSync.summary",
                        "Refreshes skip what hasn’t changed, and Lume stays responsive while it syncs."
                    )
                )
            ],
            notes: [
                text("whatsNew.2_2.simklRow.note", "A row for your Simkl watchlist on Home."),
                text("whatsNew.2_2.moreLanguages.note", "More languages to choose for audio and subtitles."),
                text("whatsNew.2_2.backgroundClose.note", "Lume no longer gets closed in the background.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(2, 1),
            highlights: [
                WhatsNewItem(
                    id: "2.1.more-sports",
                    symbol: "tennis.racket",
                    title: text("whatsNew.2_1.moreSports.title", "More Sports"),
                    summary: text(
                        "whatsNew.2_1.moreSports.summary",
                        "Cricket and tennis join Sports, and Formula 1 sessions find their channel."
                    ),
                    isPro: true
                ),
                WhatsNewItem(
                    id: "2.1.faster-start",
                    symbol: "bolt",
                    title: text("whatsNew.2_1.fasterStart.title", "Faster Start"),
                    summary: text(
                        "whatsNew.2_1.fasterStart.summary",
                        "With several playlists, Lume waits only for the one you’re watching."
                    )
                )
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(2, 0),
            highlights: [
                WhatsNewItem(
                    id: "2.0.sports",
                    symbol: "sportscourt",
                    title: text("whatsNew.2_0.sports.title", "Sports"),
                    summary: text(
                        "whatsNew.2_0.sports.summary",
                        "Live and upcoming games, standings and results, each linked to the channel showing it."
                    ),
                    isPro: true
                ),
                WhatsNewItem(
                    id: "2.0.media-servers",
                    symbol: "server.rack",
                    title: text("whatsNew.2_0.mediaServers.title", "Your Own Media Server"),
                    summary: text(
                        "whatsNew.2_0.mediaServers.summary",
                        "Add Plex, Jellyfin, Emby or a WebDAV share as a source."
                    )
                ),
                WhatsNewItem(
                    id: "2.0.simkl",
                    symbol: "checkmark.circle",
                    title: text("whatsNew.2_0.simkl.title", "Simkl"),
                    summary: text(
                        "whatsNew.2_0.simkl.summary",
                        "Track what you watch with Simkl, and import your history."
                    )
                )
            ],
            notes: [
                text("whatsNew.2_0.competitions.note", "Sports covers 150 competitions across eleven sports.")
            ]
        )
    ]
}

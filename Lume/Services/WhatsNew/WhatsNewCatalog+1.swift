//
//  WhatsNewCatalog+1.swift
//  Lume
//
//  The 1.x releases of the What’s New history, newest first.
//

import Foundation

extension WhatsNewCatalog {
    static let releases1: [WhatsNewRelease] = [
        WhatsNewRelease(
            version: AppVersion(1, 9),
            highlights: [
                WhatsNewItem(
                    id: "1.9.audio-language",
                    symbol: "speaker.wave.2",
                    title: text("whatsNew.1_9.audioLanguage.title", "Your Language First"),
                    summary: text(
                        "whatsNew.1_9.audioLanguage.summary",
                        "Lume picks the audio track in your preferred language."
                    )
                ),
                WhatsNewItem(
                    id: "1.9.next-previous",
                    symbol: "forward.end",
                    title: text("whatsNew.1_9.nextPrevious.title", "Next and Previous"),
                    summary: text(
                        "whatsNew.1_9.nextPrevious.summary",
                        "Jump to the next episode or channel straight from the player controls."
                    )
                ),
                WhatsNewItem(
                    id: "1.9.sync-status",
                    symbol: "arrow.triangle.2.circlepath",
                    title: text("whatsNew.1_9.syncStatus.title", "Sync Status"),
                    summary: text(
                        "whatsNew.1_9.syncStatus.summary",
                        "See when each playlist last synced, and when a sync didn’t go through."
                    )
                ),
                WhatsNewItem(
                    id: "1.9.live-activity",
                    symbol: "arrow.down.circle",
                    title: text("whatsNew.1_9.liveActivity.title", "Downloads on the Lock Screen"),
                    summary: text(
                        "whatsNew.1_9.liveActivity.summary",
                        "Follow your downloads on the Lock Screen and in the Dynamic Island."
                    ),
                    platforms: [.iOS]
                ),
                WhatsNewItem(
                    id: "1.9.remote",
                    symbol: "appletvremote.gen4",
                    title: text("whatsNew.1_9.remote.title", "Your Remote, Your Way"),
                    summary: text(
                        "whatsNew.1_9.remote.summary",
                        "Choose which way the remote changes channels, or turn off swipe gestures."
                    ),
                    platforms: [.tvOS]
                )
            ],
            notes: [
                text("whatsNew.1_9.fasterImport.note", "Playlists import up to three times faster."),
                text("whatsNew.1_9.multiViewMute.note", "Multi-View no longer freezes when a tile is muted.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(1, 8),
            highlights: [
                WhatsNewItem(
                    id: "1.8.long-press-favorite",
                    symbol: "star",
                    title: text("whatsNew.1_8.longPressFavorite.title", "Favorite with a Long Press"),
                    summary: text(
                        "whatsNew.1_8.longPressFavorite.summary",
                        "Long-press a movie or series to add it to your favorites."
                    )
                ),
                WhatsNewItem(
                    id: "1.8.next-episode",
                    symbol: "forward.end",
                    title: text("whatsNew.1_8.nextEpisode.title", "Smarter Next Episode"),
                    summary: text(
                        "whatsNew.1_8.nextEpisode.summary",
                        "The next episode is offered as soon as the credits start."
                    )
                ),
                WhatsNewItem(
                    id: "1.8.quick-switch",
                    symbol: "person.crop.circle",
                    title: text("whatsNew.1_8.quickSwitch.title", "Quick Switch"),
                    summary: text(
                        "whatsNew.1_8.quickSwitch.summary",
                        "Change playlist or profile from anywhere."
                    ),
                    platforms: [.tvOS]
                )
            ],
            notes: [
                text("whatsNew.1_8.downloadsContinue.note", "Downloads keep going when you leave the app."),
                text("whatsNew.1_8.pinSync.note", "Your parental PIN and locks sync across your devices."),
                text("whatsNew.1_8.hiddenEverywhere.note", "Hidden categories stay hidden on Home, in Search and in For You.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(1, 7),
            highlights: [
                WhatsNewItem(
                    id: "1.7.multi-view",
                    symbol: "rectangle.split.2x2",
                    title: text("whatsNew.1_7.multiView.title", "Multi-View"),
                    summary: text(
                        "whatsNew.1_7.multiView.summary",
                        "Watch up to four live channels at once."
                    ),
                    isPro: true
                ),
                WhatsNewItem(
                    id: "1.7.channel-menu",
                    symbol: "hand.tap",
                    title: text("whatsNew.1_7.channelMenu.title", "Channel Shortcuts"),
                    summary: text(
                        "whatsNew.1_7.channelMenu.summary",
                        "Long-press a channel on Home or in the guide for quick actions."
                    )
                ),
                WhatsNewItem(
                    id: "1.7.bulk-hide",
                    symbol: "eye.slash",
                    title: text("whatsNew.1_7.bulkHide.title", "Hide Things Faster"),
                    summary: text(
                        "whatsNew.1_7.bulkHide.summary",
                        "Hide or show many categories at once, and search the list."
                    )
                )
            ],
            notes: [
                text("whatsNew.1_7.vidhub.note", "Open videos in VidHub."),
                text("whatsNew.1_7.channelSurfing.note", "Changing channels stays in the list you started from.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(1, 6),
            highlights: [
                WhatsNewItem(
                    id: "1.6.subtitle-search",
                    symbol: "captions.bubble",
                    title: text("whatsNew.1_6.subtitleSearch.title", "Find Subtitles"),
                    summary: text(
                        "whatsNew.1_6.subtitleSearch.summary",
                        "Search and load subtitles from OpenSubtitles, right in the player."
                    )
                )
            ],
            notes: [
                text("whatsNew.1_6.artworkFade.note", "Artwork fades in smoothly.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(1, 5),
            highlights: [
                WhatsNewItem(
                    id: "1.5.subscription",
                    symbol: "crown",
                    title: text("whatsNew.1_5.subscription.title", "Monthly Lume Pro"),
                    summary: text(
                        "whatsNew.1_5.subscription.summary",
                        "Lume Pro is now a monthly subscription you can manage or cancel in Settings. Lifetime unlocks stay as they are."
                    )
                ),
                WhatsNewItem(
                    id: "1.5.appearance",
                    symbol: "circle.lefthalf.filled",
                    title: text("whatsNew.1_5.appearance.title", "Light or Dark"),
                    summary: text(
                        "whatsNew.1_5.appearance.summary",
                        "Choose System, Dark or Light in Settings."
                    ),
                    platforms: [.iOS, .macOS, .visionOS]
                ),
                WhatsNewItem(
                    id: "1.5.stalker-browse",
                    symbol: "film.stack",
                    title: text("whatsNew.1_5.stalkerBrowse.title", "Faster Stalker Portals"),
                    summary: text(
                        "whatsNew.1_5.stalkerBrowse.summary",
                        "Movies and series load as you browse, and search runs on the portal."
                    )
                )
            ],
            notes: [
                text("whatsNew.1_5.newPlayer.note", "A new built-in player to try, in beta."),
                text("whatsNew.1_5.clearRecent.note", "Clear your Recently Watched channels."),
                text("whatsNew.1_5.missingArtwork.note", "Posters and logos show up again on playlists that were missing them.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(1, 4),
            highlights: [
                WhatsNewItem(
                    id: "1.4.airplay",
                    symbol: "airplayvideo",
                    title: text("whatsNew.1_4.airplay.title", "AirPlay"),
                    summary: text(
                        "whatsNew.1_4.airplay.summary",
                        "Send what you’re watching to an Apple TV or AirPlay TV."
                    ),
                    platforms: [.iOS, .macOS, .visionOS]
                ),
                WhatsNewItem(
                    id: "1.4.guide-catch-up",
                    symbol: "calendar",
                    title: text("whatsNew.1_4.guideCatchUp.title", "Catch Up from the Guide"),
                    summary: text(
                        "whatsNew.1_4.guideCatchUp.summary",
                        "Play past programmes straight from the TV guide."
                    )
                ),
                WhatsNewItem(
                    id: "1.4.all-sources",
                    symbol: "rectangle.stack",
                    title: text("whatsNew.1_4.allSources.title", "All Your Sources in One Row"),
                    summary: text(
                        "whatsNew.1_4.allSources.summary",
                        "See which of your playlists carry a title, all in one place."
                    )
                ),
                WhatsNewItem(
                    id: "1.4.favorites",
                    symbol: "star",
                    title: text("whatsNew.1_4.favorites.title", "All Favorites Together"),
                    summary: text(
                        "whatsNew.1_4.favorites.summary",
                        "Manage your favorite channels, movies and series in one list."
                    )
                )
            ],
            notes: [
                text("whatsNew.1_4.ratings.note", "Ratings from IMDb, Rotten Tomatoes and Metacritic."),
                text("whatsNew.1_4.hiddenSync.note", "Hidden channels and your category order sync with iCloud."),
                text("whatsNew.1_4.fasterGuide.note", "A much faster TV guide on Apple TV.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(1, 3),
            highlights: [
                WhatsNewItem(
                    id: "1.3.stalker",
                    symbol: "antenna.radiowaves.left.and.right",
                    title: text("whatsNew.1_3.stalker.title", "Stalker Portals"),
                    summary: text(
                        "whatsNew.1_3.stalker.summary",
                        "Add Stalker portals next to your other playlists."
                    )
                ),
                WhatsNewItem(
                    id: "1.3.category-search",
                    symbol: "magnifyingglass",
                    title: text("whatsNew.1_3.categorySearch.title", "Find Categories Faster"),
                    summary: text(
                        "whatsNew.1_3.categorySearch.summary",
                        "Search the Live TV category list."
                    ),
                    platforms: [.iOS]
                )
            ],
            notes: [
                text("whatsNew.1_3.fasterHome.note", "Home and syncing are faster."),
                text("whatsNew.1_3.subtitlesFixed.note", "Subtitles show up reliably, and you can pick the audio track.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(1, 2),
            highlights: [
                WhatsNewItem(
                    id: "1.2.catch-up",
                    symbol: "gobackward",
                    title: text("whatsNew.1_2.catchUp.title", "Catch Up on Live TV"),
                    summary: text(
                        "whatsNew.1_2.catchUp.summary",
                        "Watch programmes you missed, right from the player."
                    )
                )
            ],
            notes: [
                text("whatsNew.1_2.genrePages.note", "Genres load page by page.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(1, 1),
            highlights: [
                WhatsNewItem(
                    id: "1.1.for-you",
                    symbol: "sparkles",
                    title: text("whatsNew.1_1.forYou.title", "For You"),
                    summary: text(
                        "whatsNew.1_1.forYou.summary",
                        "Recommendations based on what you watch, which you can rate up or down."
                    ),
                    isPro: true
                ),
                WhatsNewItem(
                    id: "1.1.home-layout",
                    symbol: "rectangle.3.group",
                    title: text("whatsNew.1_1.homeLayout.title", "Make Home Your Own"),
                    summary: text(
                        "whatsNew.1_1.homeLayout.summary",
                        "Choose which rows appear on Home."
                    )
                ),
                WhatsNewItem(
                    id: "1.1.trakt-import",
                    symbol: "clock.arrow.circlepath",
                    title: text("whatsNew.1_1.traktImport.title", "Import Your Watch History"),
                    summary: text(
                        "whatsNew.1_1.traktImport.summary",
                        "Bring in what you’ve already watched on Trakt."
                    )
                ),
                WhatsNewItem(
                    id: "1.1.languages",
                    symbol: "globe",
                    title: text("whatsNew.1_1.languages.title", "Seven New Languages"),
                    summary: text(
                        "whatsNew.1_1.languages.summary",
                        "Lume now speaks French, Spanish, Italian, Portuguese, Japanese, Korean and Chinese."
                    )
                )
            ],
            notes: [
                text("whatsNew.1_1.offerCodes.note", "Redeem offer codes in the app."),
                text("whatsNew.1_1.clearHistory.note", "Clear your watch history in Settings."),
                text("whatsNew.1_1.icon.note", "A new app icon.")
            ]
        ),
        WhatsNewRelease(
            version: AppVersion(1, 0),
            highlights: [
                WhatsNewItem(
                    id: "1.0.welcome",
                    symbol: "play.tv",
                    title: text("whatsNew.1_0.welcome.title", "Welcome to Lume"),
                    summary: text(
                        "whatsNew.1_0.welcome.summary",
                        "Watch live TV, movies and series from your playlists."
                    )
                ),
                WhatsNewItem(
                    id: "1.0.guide",
                    symbol: "calendar.day.timeline.left",
                    title: text("whatsNew.1_0.guide.title", "Live TV with a Guide"),
                    summary: text(
                        "whatsNew.1_0.guide.summary",
                        "See what’s on now and next on every channel."
                    )
                ),
                WhatsNewItem(
                    id: "1.0.resume",
                    symbol: "play.circle",
                    title: text("whatsNew.1_0.resume.title", "Pick Up Where You Left Off"),
                    summary: text(
                        "whatsNew.1_0.resume.summary",
                        "Movies and series remember where you stopped, and the next episode is ready."
                    )
                ),
                WhatsNewItem(
                    id: "1.0.profiles",
                    symbol: "person.2",
                    title: text("whatsNew.1_0.profiles.title", "Profiles and Parental Controls"),
                    summary: text(
                        "whatsNew.1_0.profiles.summary",
                        "Give everyone their own profile, and lock categories with a PIN."
                    )
                ),
                WhatsNewItem(
                    id: "1.0.icloud",
                    symbol: "icloud",
                    title: text("whatsNew.1_0.icloud.title", "Synced with iCloud"),
                    summary: text(
                        "whatsNew.1_0.icloud.summary",
                        "Profiles, progress and favorites follow you across your devices."
                    )
                )
            ]
        )
    ]
}

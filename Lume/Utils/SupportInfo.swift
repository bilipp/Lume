//
//  SupportInfo.swift
//  Lume
//
//  Canonical support / contact links, shared by the iOS Settings list (tappable
//  Link rows) and the tvOS About pane (read-only text plus a scannable QR code,
//  since Apple TV can't open a URL itself). One source of truth so the two
//  surfaces can never drift.
//

import Foundation

nonisolated enum SupportInfo {
    static let website = "https://getlume.org"
    static let email = "support@getlume.org"
    static let discord = "https://discord.gg/DMnQfr69Ug"

    /// App Store listing, and the deep link that opens straight to the
    /// write-a-review composer (`?action=write-review`).
    static let appStore = "https://apps.apple.com/app/id6779551584"
    static let appStoreReview = "https://apps.apple.com/app/id6779551584?action=write-review"

    /// Scheme-stripped forms for compact on-screen display.
    static let websiteDisplay = "GetLume.org"
    static let discordDisplay = "discord.gg/DMnQfr69Ug"
    static let appStoreDisplay = "App Store"

    static var websiteURL: URL? {
        URL(string: website)
    }

    static var discordURL: URL? {
        URL(string: discord)
    }

    static var emailURL: URL? {
        URL(string: "mailto:\(email)")
    }

    static var appStoreReviewURL: URL? {
        URL(string: appStoreReview)
    }
}

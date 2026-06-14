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

    /// Scheme-stripped forms for compact on-screen display.
    static let websiteDisplay = "getlume.org"
    static let discordDisplay = "discord.gg/DMnQfr69Ug"

    static var websiteURL: URL? {
        URL(string: website)
    }

    static var discordURL: URL? {
        URL(string: discord)
    }

    static var emailURL: URL? {
        URL(string: "mailto:\(email)")
    }
}

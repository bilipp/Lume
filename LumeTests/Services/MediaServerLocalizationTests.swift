//
//  MediaServerLocalizationTests.swift
//  LumeTests
//
//  Every user-facing literal the media-server source type added — the shared
//  form chrome and the Jellyfin half of the copy — asserted present and
//  translated in all nine shipping locales. The WebDAV half is covered by
//  `WebDAVLocalizationTests`.
//

import Foundation
@testable import Lume
import Testing

@Suite("Media server localization")
struct MediaServerLocalizationTests {
    /// The add-playlist form: the picker segment, the section chrome, the field
    /// titles and placeholders, the footer lines and the tvOS hint.
    static let formKeys = [
        "Server",
        "Media Server",
        "Server URL",
        "e.g. My Media Server",
        "e.g. http://192.168.1.10:8096",
        "Username (optional)",
        "Password (optional)",
        "Enter your server address — Lume recognizes Jellyfin servers and WebDAV shares automatically.",
        "For a WebDAV share, enter the full path of the folder that holds your media — a server's root address usually isn't browsable.",
        "Leave the username and password empty for an anonymous share.",
        "The first connection asks permission to find devices on your local network. If you decline it, only the system Settings app can allow it again.",
        "Enter your server address — Jellyfin and WebDAV are detected automatically. A declined local network prompt can only be allowed again in Settings."
    ]

    /// The failures the copy deliberately tells apart: the two the detection
    /// itself raises, the two Jellyfin add-playlist ones, and the
    /// `JellyfinError` descriptions that surface as the generic
    /// connection-failed text.
    static let errorKeys = [
        "Lume couldn't recognize a media server at that address. Enter your Jellyfin server's base address, or the full path of a WebDAV folder.",
        "This Jellyfin server needs a username and password. Enter them and try again.",
        "The server rejected this username and password.",
        "That URL doesn't answer as a Jellyfin server. Enter the server's base address, e.g. http://192.168.1.10:8096.",
        "Lume couldn't reach that address on your local network. If you declined the local network prompt, only the system Settings app can allow it again.",
        "The server URL is invalid.",
        "Network error: %@",
        "The server rejected these credentials.",
        "This URL does not point to a Jellyfin server. Enter the server's base address, e.g. http://192.168.1.10:8096.",
        "Server error (HTTP %lld).",
        "The server returned a response Lume could not read."
    ]

    /// The playlist's kind label and the source-aware Live TV empty state.
    static let browseKeys = [
        "Jellyfin Server",
        "No Live Channels",
        "This Jellyfin server has no live channels here — it carries movies and series only."
    ]

    static var allKeys: [String] {
        formKeys + errorKeys + browseKeys
    }

    @Test func `every media server string is translated in all nine locales`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.allKeys {
            expectTranslatedEverywhere(key, in: catalog)
        }
    }

    @Test func `every media server string resolves to a non empty value`() {
        for key in Self.allKeys {
            let resolved = String(localized: String.LocalizationValue(key))
            #expect(!resolved.isEmpty, "\(key) resolved to an empty string")
        }
    }
}

//
//  MediaServerLocalizationTests.swift
//  LumeTests
//
//  Every user-facing literal the media-server source types added — the shared
//  form chrome plus the Jellyfin/Emby and Plex halves of the copy — asserted
//  present and translated in all nine shipping locales. The WebDAV half is
//  covered by `WebDAVLocalizationTests`.
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
        "Enter your server address — Lume recognizes Jellyfin, Emby and Plex servers and WebDAV shares automatically.",
        "For a WebDAV share, enter the full path of the folder that holds your media — a server's root address usually isn't browsable.",
        "Leave the username and password empty for an anonymous share. For Plex, enter your Plex account — or paste an X-Plex-Token in the password field.",
        "The first connection asks permission to find devices on your local network. If you decline it, only the system Settings app can allow it again.",
        "Enter your server address — Jellyfin, Emby, Plex and WebDAV are detected automatically. A declined local network prompt can only be allowed again in Settings."
    ]

    /// The failures the copy deliberately tells apart: the two the detection
    /// itself raises, the two Jellyfin/Emby add-playlist ones, and the
    /// `JellyfinError` descriptions that surface as the generic
    /// connection-failed text.
    static let errorKeys = [
        "Lume couldn't recognize a media server at that address. Enter your Jellyfin, Emby or Plex server's base address, or the full path of a WebDAV folder.",
        "This server needs a username and password. Enter them and try again.",
        "The server rejected this username and password.",
        "That URL doesn't answer as a Jellyfin or Emby server. Enter the server's base address, e.g. http://192.168.1.10:8096.",
        "Lume couldn't reach that address on your local network. If you declined the local network prompt, only the system Settings app can allow it again.",
        "The server URL is invalid.",
        "Network error: %@",
        "The server rejected these credentials.",
        "This URL does not point to a Jellyfin or Emby server. Enter the server's base address, e.g. http://192.168.1.10:8096.",
        "Server error (HTTP %lld).",
        "The server returned a response Lume could not read."
    ]

    /// Plex's own copy: the three ways its single 401 is explained, plus the
    /// two address failures its error type describes.
    static let plexErrorKeys = [
        "Plex rejected this account. Check your username and password — with two-factor authentication, add the current code to the end of the password.",
        "This Plex server rejected that token. Paste the X-Plex-Token from your server, or enter your Plex account's username and password instead.",
        "This Plex server needs a sign-in. Enter your Plex account's username and password, or paste an X-Plex-Token in the password field.",
        "That URL doesn't answer as a Plex server. Enter the server's base address, e.g. http://192.168.1.10:32400.",
        "This URL does not point to a Plex server. Enter the server's base address, e.g. http://192.168.1.10:32400.",
        "The Plex server rejected this token."
    ]

    /// The playlist kind labels, the Plex-only edit fields and the
    /// source-aware Live TV empty state.
    static let browseKeys = [
        "Jellyfin Server",
        "Emby Server",
        "Plex Server",
        "Password or token (optional)",
        "Token",
        "No Live Channels",
        "This server has no live channels here — it carries movies and series only."
    ]

    static var allKeys: [String] {
        formKeys + errorKeys + plexErrorKeys + browseKeys
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

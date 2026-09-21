//
//  WebDAVLocalizationTests.swift
//  LumeTests
//
//  Every user-facing literal the WebDAV source type added, asserted present and
//  translated in all nine shipping locales.
//

import Foundation
@testable import Lume
import Testing

@Suite("WebDAV localization")
struct WebDAVLocalizationTests {
    /// The add-playlist form: the picker segment, the section chrome, the field
    /// titles and placeholders, and the tvOS hint.
    static let formKeys = [
        "WebDAV",
        "WebDAV Share",
        "Share URL",
        "e.g. My Media Server",
        "e.g. http://192.168.1.10:8080/Movies/",
        "Enter the full URL of the folder that holds your media — a server's root address usually isn't browsable.",
        // Shared with the other media-server kinds, so the WebDAV sentence
        // now carries the Plex clause too.
        "Leave the username and password empty for an anonymous share. For Plex, enter your Plex account — or paste an X-Plex-Token in the password field.",
        "The first connection asks permission to find devices on your local network. If you decline it, only the system Settings app can allow it again.",
        "Enter the full folder URL — a server's root address isn't browsable. Username and password are optional. A declined local network prompt can only be allowed again in Settings."
    ]

    /// The four add-playlist failures the copy deliberately tells apart, plus
    /// the `WebDAVError` descriptions that surface as the generic
    /// connection-failed text.
    static let errorKeys = [
        "The server rejected this username and password. Leave both empty if the share allows anonymous access.",
        "That URL doesn't answer as a WebDAV share. Enter the full path of the shared folder, not just the server address.",
        "That folder is empty. Enter the full path of the folder that holds your media — a server's root address usually lists nothing.",
        "Lume couldn't reach that address on your local network. If you declined the local network prompt, only the system Settings app can allow it again.",
        "The share URL is invalid.",
        "Network error: %@",
        "The server rejected these credentials.",
        "This URL does not point to a WebDAV share. Enter the full path of the shared folder.",
        "Server error (HTTP %lld).",
        "The server returned a response Lume could not read."
    ]

    /// The sync-progress step and its detail line, and the source-aware Live TV
    /// empty state.
    static let browseKeys = [
        "Scanning folders",
        "%lld files in %lld folders",
        "No Live Channels",
        "This WebDAV share has no live channels — it carries movies and series only."
    ]

    static var allKeys: [String] {
        formKeys + errorKeys + browseKeys
    }

    @Test func `every WebDAV string is translated in all nine locales`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.allKeys {
            expectTranslatedEverywhere(key, in: catalog)
        }
    }

    @Test func `every WebDAV string resolves to a non empty value`() {
        for key in Self.allKeys {
            let resolved = String(localized: String.LocalizationValue(key))
            #expect(!resolved.isEmpty, "\(key) resolved to an empty string")
        }
    }

    /// The local-network prompt lives in `InfoPlist.xcstrings`, not
    /// `Localizable.xcstrings`: a usage description is read from the bundle's
    /// Info.plist by the system, never through `String(localized:)`.
    @Test func `the local network usage description is translated in all nine locales`() throws {
        let url = repoRootURL().appendingPathComponent("Lume/InfoPlist.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(root?["strings"] as? [String: Any])
        let entry = try #require(strings["NSLocalNetworkUsageDescription"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])

        for locale in shippingLocales {
            let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
            let state = unit?["state"] as? String
            let value = unit?["value"] as? String ?? ""
            #expect(state == "translated", "\(locale) is not translated")
            #expect(value.isEmpty == false, "\(locale) is empty")
        }
    }
}

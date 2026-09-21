//
//  MediaServerFlavor.swift
//  Lume
//
//  Jellyfin and Emby speak the same HTTP API — Jellyfin is a fork of Emby, and
//  both still authenticate with the `MediaBrowser` authorization scheme, page
//  `/Users/{id}/Items` the same way and serve the same image and stream
//  endpoints. One client and one sync pipeline therefore cover both; this is
//  the small amount that genuinely differs between them.
//

import Foundation

nonisolated enum MediaServerFlavor: String, CaseIterable, Hashable {
    case jellyfin
    case emby

    var sourceType: PlaylistSourceType {
        switch self {
        case .jellyfin: .jellyfin
        case .emby: .emby
        }
    }

    /// Product name, not localized: both are trademarks shown verbatim.
    var displayName: String {
        switch self {
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        }
    }

    /// The infix every catalog row this pipeline writes carries, between the
    /// playlist UUID and the server's item id. It scopes the prune sweep to
    /// rows this pipeline owns, so a playlist that changed flavour — or a
    /// store holding both kinds — can never have one sweep delete the other's
    /// rows.
    var idInfix: String {
        rawValue
    }

    init?(sourceType: PlaylistSourceType) {
        switch sourceType {
        case .jellyfin: self = .jellyfin
        case .emby: self = .emby
        case .xtream, .m3u, .stalker, .webdav, .plex: return nil
        }
    }
}
